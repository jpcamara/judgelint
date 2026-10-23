# frozen_string_literal: true

module Judgelint
  # Judges files against the rules that govern them, and rules against their
  # examples, in two steps: plan every request first, so a run can be priced
  # and refused before anything is sent, then send them.
  #
  # Each file's requests carry the whole numbered file as state and one
  # question per rule and window, so a file's verdicts never depend on which
  # other files ran alongside it. Every model is asked every question, all of a
  # file's requests go out at once, and a question's answer is the models'
  # average. A rule's verdict is its worst window.
  class Runner
    # One file's work: the questions to ask, each model's answers (from the
    # cache or the model), and the requests still to send.
    class Job
      attr_reader :source, :state, :state_digest, :questions, :suppressed, :answers, :requests, :expected
      attr_accessor :skipped

      # The state is built and hashed once: it's the whole file, and every
      # question's cache key needs its hash.
      def initialize(source, questions, suppressed, expected: nil)
        @source = source
        @state = source.state
        @state_digest = Digest::SHA256.hexdigest(@state)
        @questions = questions
        @suppressed = suppressed
        @answers = {} # model index => {question key => probability or nil}
        @requests = []
        @expected = expected
        @skipped = false
      end
    end

    # Questions sent together to one model, and their estimated input tokens.
    class Request
      attr_reader :model, :questions, :tokens

      def initialize(model, questions, tokens)
        @model = model
        @questions = questions
        @tokens = tokens
      end
    end

    # +clients+ has one Client per model in config.models.
    def initialize(config:, rules:, clients:, cache:)
      @config = config
      @rules = rules
      @clients = clients
      @cache = cache
    end

    # +changes+ ({path => lines or :all}, from Changes.since) limits each file
    # to the windows a change touched, and directories to those with a change.
    # Rules that read different context files can't share a request, so a
    # file gets one job per set of context files.
    def plan(paths, directories: [], changes: nil)
      files = paths.flat_map do |path|
        rules = @rules.select { |rule| !rule.directory? && rule.applies_to?(path) }
        by_context(rules) { |context, group| plan_file(Source.new(path, context: context), group, changes ? changes[path] : :all) }
      end
      units = directories.flat_map do |dir|
        next [] if changes && changes.keys.none? { |path| path.start_with?("#{dir}/") }

        rules = @rules.select { |rule| rule.directory? && rule.applies_to?(dir) }
        by_context(rules) { |context, group| plan_file(Source.directory(dir, context: context), group, :all) }
      end
      files + units
    end

    attr_reader :untested

    # Files under <examples>/pass must not be judged violations, files under
    # <examples>/fail must. The model sees each example's path relative to its
    # pass/ or fail/ directory, so the directory never gives the answer away.
    # A rule with examples needs both kinds, checked before anything is sent;
    # rules with none are listed in +untested+.
    def plan_examples
      jobs = []
      missing = []
      @untested = []
      @rules.each do |rule|
        found = %i[pass fail].to_h { |expected| [expected, example_paths(rule, expected)] }
        if found.values.all?(&:empty?)
          @untested << rule
          next
        end

        found.each do |expected, paths|
          dir = File.join(rule.examples_dir, expected.to_s)
          missing << "#{dir}/" if paths.empty?
          paths.each do |path|
            shown = path.delete_prefix("#{dir}/")
            context = rule.context_files
            source = rule.directory? ? Source.directory(path, shown_as: shown, context: context)
                                     : Source.new(path, shown_as: shown, context: context)
            jobs << plan_file(source, [rule], :all, expected: expected)
          end
        end
      end
      raise ConfigError, "Examples need both kinds: add some to #{missing.join(', ')}" unless missing.empty?

      jobs
    end

    def request_count(jobs)
      jobs.sum { |job| job.requests.size }
    end

    def estimated_tokens(jobs)
      jobs.sum { |job| job.requests.sum(&:tokens) }
    end

    # Nil when a model has no price.
    def estimated_cost(jobs)
      requests = jobs.flat_map(&:requests)
      prices = requests.map { |request| @clients[request.model].endpoint.price_per_million }
      return nil if prices.include?(nil)

      requests.each_with_index.sum { |request, index| request.tokens * prices[index] / 1_000_000.0 }
    end

    # Returns each job's verdicts, in the jobs' order.
    def execute(jobs)
      Pool.map(jobs, Config::THREADS) do |job|
        ask(job)
        verdicts(job)
      end
    ensure
      @cache.save
    end

    private

    # A directory rule's examples are the directories under pass/ and fail/.
    def example_paths(rule, expected)
      dir = File.join(rule.examples_dir, expected.to_s)
      return Dir.glob(File.join(dir, "*")).select { |path| File.directory?(path) }.sort if rule.directory?

      Glob.expand([File.join(dir, "**", "*")])
    end

    def plan_file(source, rules, lines, expected: nil)
      unknown = source.suppressed_ids - @rules.map(&:id)
      raise ConfigError, "#{source.path}: judgelint:disable names unknown rules #{unknown.join(', ')}" unless unknown.empty?

      questions = {}
      suppressed = []
      rules.each do |rule|
        ranges = rule.ranges(source, Config::WINDOW_LINES).select { |first, last| touched?(lines, first, last) }
        next if ranges.empty?

        kept = ranges.reject { |first, last| source.suppressed?(rule.id, first, last) }
        if kept.empty?
          suppressed << rule
        else
          questions[rule] = kept.map { |first, last| Question.new(rule, first, last) }
        end
      end
      job = Job.new(source, questions, suppressed, expected: expected)
      pack(job)
      job
    end

    def by_context(rules)
      rules.group_by(&:context).map { |globs, group| yield(Glob.expand(globs), group) }
    end

    def touched?(lines, first, last)
      lines == :all || (lines || []).any? { |line| line.between?(first, last) }
    end

    # For each model, packs the questions its cache can't answer into as few
    # requests as fit its limits. A file whose state and widest question are
    # over a model's limit is skipped: it's reported, never sent.
    def pack(job)
      @clients.each_with_index do |client, model|
        answers = job.answers[model] = {}
        pending = []
        job.questions.each_value do |questions|
          questions.each do |question|
            cached = @cache.fetch(cache_key(question, job, client))
            cached.nil? ? pending << question : answers[question.key] = cached
          end
        end
        next if pending.empty?

        limits = client.endpoint
        base = client.tokens(job.state, [])
        sizes = pending.map { |question| client.question_tokens(question) }
        if base + sizes.max >= limits.max_state_tokens
          job.skipped = true
          job.requests.clear
          return
        end

        batch = []
        tokens = base
        pending.each_with_index do |question, index|
          if !batch.empty? && (tokens + sizes[index] > limits.max_request_tokens || batch.size >= limits.batch_size)
            job.requests << Request.new(model, batch, tokens)
            batch = []
            tokens = base
          end
          batch << question
          tokens += sizes[index]
        end
        job.requests << Request.new(model, batch, tokens)
      end
    end

    # Sends every request at once: a file's packed requests and every model's.
    def ask(job)
      state = job.state.dup # Spinel can't yet pass the Job's shared String along
      results = Pool.map(job.requests, job.requests.size) do |request|
        @clients[request.model].judge(state, request.questions)
      end
      job.requests.each_with_index do |request, index|
        client = @clients[request.model]
        request.questions.each do |question|
          probability = results[index][question.key]
          @cache.store(cache_key(question, job, client), probability) unless probability.nil?
          job.answers[request.model][question.key] = probability
        end
      end
    end

    # The models' average for a question, or nil if every model refused it.
    def answer(job, question)
      values = job.answers.values.map { |answers| answers[question.key] }.compact
      values.empty? ? nil : values.sum / values.size
    end

    def verdicts(job)
      path = job.source.path
      found = job.questions.map { |rule, questions| verdict_for(rule, path, questions, job) }
      found += job.suppressed.map { |rule| Verdict.new(rule: rule, path: path, probability: nil, status: :suppressed) }
      job.expected ? found.map { |verdict| verdict.as_example(job.expected) } : found
    end

    def verdict_for(rule, path, questions, job)
      return Verdict.new(rule: rule, path: path, probability: nil, status: :skipped) if job.skipped

      answered = questions.filter_map do |question|
        probability = answer(job, question)
        [question, probability] unless probability.nil?
      end
      return Verdict.new(rule: rule, path: path, probability: nil, status: :refused) if answered.empty?

      worst, probability = answered.max_by { |_question, value| rule.violation_probability(value) }
      lines = rule.directory? ? nil : [worst.first, worst.last]
      Verdict.classify(rule, path, probability, warn_at: @config.warn_at, lines: lines)
    end

    # Each model's answers are cached on their own, so adding a model asks
    # only the new one.
    def cache_key(question, job, client)
      endpoint = client.endpoint
      Cache.key(question.digest, job.state_digest, "#{endpoint.provider}/#{endpoint.model}")
    end
  end
end
