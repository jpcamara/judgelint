# frozen_string_literal: true

module Judgelint
  # Judges files against the rules that govern them, and rules against their
  # examples, in two steps: plan every request first, so a run can be priced
  # and refused before anything is sent, then send them.
  #
  # Each file's requests carry the whole numbered file as state and one
  # question per rule and window, so a file's verdicts never depend on which
  # other files ran alongside it. A rule's verdict is its worst window.
  class Runner
    # One file's work: the questions to ask, answers the cache already has,
    # and the requests the rest are packed into.
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
        @answers = {}
        @requests = []
        @expected = expected
        @skipped = false
      end
    end

    # Questions sent together, and their estimated input tokens.
    class Request
      attr_reader :questions, :tokens

      def initialize(questions, tokens)
        @questions = questions
        @tokens = tokens
      end
    end

    def initialize(config:, rules:, client:, cache:)
      @config = config
      @rules = rules
      @client = client
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

    # Files under rules/<id>/pass must not be judged violations, files under
    # rules/<id>/fail must. The model sees each example's path relative to its
    # pass/ or fail/ directory, so the directory never gives the answer away.
    # Every rule needs both kinds, checked before anything is sent.
    def plan_examples
      jobs = []
      missing = []
      @rules.each do |rule|
        %i[pass fail].each do |expected|
          dir = File.join(rule.examples_dir, expected.to_s)
          # A directory rule's examples are the directories under pass/ and fail/.
          paths = rule.directory? ? Dir.glob(File.join(dir, "*")).select { |path| File.directory?(path) }.sort
                                  : Glob.expand([File.join(dir, "**", "*")])
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
      raise ConfigError, "Every rule needs pass and fail examples; add some to #{missing.join(', ')}" unless missing.empty?

      jobs
    end

    def request_count(jobs)
      jobs.sum { |job| job.requests.size } * @config.repeat
    end

    def estimated_tokens(jobs)
      jobs.sum { |job| job.requests.sum(&:tokens) } * @config.repeat
    end

    # Returns each job's verdicts, in the jobs' order.
    def execute(jobs)
      Pool.map(jobs, @config.threads) do |job|
        ask(job)
        verdicts(job)
      end
    ensure
      @cache.save
    end

    private

    def plan_file(source, rules, lines, expected: nil)
      unknown = source.suppressed_ids - @rules.map(&:id)
      raise ConfigError, "#{source.path}: judgelint:disable names unknown rules #{unknown.join(', ')}" unless unknown.empty?

      questions = {}
      suppressed = []
      rules.each do |rule|
        ranges = rule.ranges(source, @config.window_lines).select { |first, last| touched?(lines, first, last) }
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

    # Packs the questions the cache can't answer into as few requests as fit
    # the provider's limits. A file whose state and widest question are
    # already over the limit is skipped: it's reported, never sent.
    def pack(job)
      pending = []
      job.questions.each_value do |questions|
        questions.each do |question|
          cached = @cache.fetch(cache_key(question, job))
          cached.nil? ? pending << question : job.answers[question.key] = cached
        end
      end
      return if pending.empty?

      base = @client.tokens(job.state, [])
      sizes = pending.map { |question| @client.question_tokens(question) }
      if base + sizes.max >= @config.max_state_tokens
        job.skipped = true
        return
      end

      batch = []
      tokens = base
      pending.each_with_index do |question, index|
        if !batch.empty? && (tokens + sizes[index] > @config.max_request_tokens || batch.size >= @config.batch_size)
          job.requests << Request.new(batch, tokens)
          batch = []
          tokens = base
        end
        batch << question
        tokens += sizes[index]
      end
      job.requests << Request.new(batch, tokens)
    end

    # With repeat above 1, each request is sent that many times and the answers
    # averaged, which smooths a model that doesn't answer the same way twice.
    def ask(job)
      state = job.state.dup # Spinel can't yet pass the Job's shared String along
      job.requests.each do |request|
        samples = Array.new(@config.repeat) { @client.judge(state, request.questions) }
        request.questions.each do |question|
          values = samples.map { |answers| answers[question.key] }.compact
          probability = values.empty? ? nil : values.sum / values.size
          @cache.store(cache_key(question, job), probability) unless probability.nil?
          job.answers[question.key] = probability
        end
      end
    end

    def verdicts(job)
      path = job.source.path
      found = job.questions.map { |rule, questions| verdict_for(rule, path, questions, job) }
      found += job.suppressed.map { |rule| Verdict.new(rule: rule, path: path, probability: nil, status: :suppressed) }
      job.expected ? found.map { |verdict| verdict.as_example(job.expected) } : found
    end

    def verdict_for(rule, path, questions, job)
      return Verdict.new(rule: rule, path: path, probability: nil, status: :skipped) if job.skipped

      answered = questions.reject { |question| job.answers[question.key].nil? }
      return Verdict.new(rule: rule, path: path, probability: nil, status: :refused) if answered.empty?

      worst = answered.max_by { |question| rule.violation_probability(job.answers[question.key]) }
      lines = rule.directory? ? nil : [worst.first, worst.last]
      Verdict.classify(rule, path, job.answers[worst.key], warn_at: @config.warn_at, lines: lines)
    end

    def cache_key(question, job)
      Cache.key(question.digest, job.state_digest, @config.model_label)
    end
  end
end
