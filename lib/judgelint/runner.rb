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
      attr_reader :source, :state, :state_digest, :questions, :answers, :requests, :expected
      attr_accessor :skipped

      # The state is built and hashed once: it's the whole file, and every
      # question's cache key needs its hash. Rules from a spec read its prose
      # alongside the file, as team_rules.
      def initialize(source, questions, prose: nil, expected: nil)
        @source = source
        @state = prose ? { "team_rules" => prose, "file" => source.state } : source.state
        @state_digest = Digest::SHA256.hexdigest(JSON.generate(@state))
        @questions = questions
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

    # One range's averaged answers: the probability it breaks the rule, and
    # where, when the model is sure enough of one line or file.
    class Window
      attr_reader :first, :last, :probability, :place

      def initialize(first, last, probability, place)
        @first = first
        @last = last
        @probability = probability
        @place = place
      end
    end

    # A finding names a line or file when it gets at least this share of the
    # "where" answer.
    PLACE_AT = 0.5
    # A choice takes at most this many options.
    MAX_OPTIONS = 255

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
      questions = {}
      rules.each do |rule|
        ranges = rule.ranges(source, Config::WINDOW_LINES).select { |first, last| touched?(lines, first, last) }
        next if ranges.empty?

        asked = []
        ranges.each do |first, last|
          asked << Question.new(rule, first, last)
          places = places(source, rule, first, last)
          asked << Question.new(rule, first, last, kind: :where, places: places) unless places.empty?
          asked << Question.new(rule, first, last, kind: :excuse) if source.hinted?(first, last)
        end
        questions[rule] = asked
      end
      job = Job.new(source, questions, prose: rules.first&.prose, expected: expected)
      pack(job)
      job
    end

    # The options for asking where a bullet is broken: the range's line ids, or
    # the directory's files. None for a rule written as a question, or past
    # what a choice can hold.
    def places(source, rule, first, last)
      return [] unless rule.convention

      places = rule.directory? ? source.members.map { |_path, shown| shown } : (first..last).map { |line| "L#{line}" }
      places.size > MAX_OPTIONS ? [] : places
    end

    # Rules that read different context files or spec prose can't share a request.
    def by_context(rules)
      rules.group_by { |rule| [rule.context, rule.prose] }.map { |(globs, _prose), group| yield(Glob.expand(globs), group) }
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

    def verdicts(job)
      path = job.source.path
      found = job.questions.map { |rule, questions| verdict_for(rule, path, questions, job) }
      job.expected ? found.map { |verdict| verdict.as_example(job.expected) } : found
    end

    # A window's probability of a violation is the average of its verdict
    # over the models, and its place is the line or file the models' "where"
    # answers agree on. A rule's verdict is its worst window. A window whose
    # judgehint excuses it, by the same average and threshold, is reported as
    # excused instead, unless another window breaks the rule.
    def verdict_for(rule, path, questions, job)
      return Verdict.new(rule: rule, path: path, probability: nil, status: :skipped) if job.skipped

      open = []
      excused = []
      questions.group_by { |question| [question.first, question.last] }.each do |(first, last), asked|
        values = []
        excuses = []
        spread = {}
        asked.each do |question|
          job.answers.each_value do |answers|
            answer = answers[question.key]
            next if answer.nil?

            if question.excuse?
              excuses << answer
            elsif question.where?
              answer.each { |place, probability| spread[place] = (spread[place] || 0.0) + probability }
            else
              values << question.violation(answer)
            end
          end
        end
        next if values.empty?

        window = Window.new(first, last, values.sum / values.size, agreed(spread))
        if !excuses.empty? && excuses.sum / excuses.size >= rule.threshold
          excused << window
        else
          open << window
        end
      end
      return Verdict.new(rule: rule, path: path, probability: nil, status: :refused) if open.empty? && excused.empty?

      found = worst(rule, path, open, job.source)
      return found if found && found.status != :pass

      hidden = worst(rule, path, excused, job.source)
      return found || hidden if hidden.nil? || hidden.status == :pass

      Verdict.new(rule: rule, path: path, probability: hidden.probability, status: :excused, lines: hidden.lines,
                  line: hidden.line, file: hidden.file)
    end

    # The place with at least PLACE_AT of the summed "where" probabilities.
    # A loop rather than max_by, which Spinel's Hash doesn't have yet.
    def agreed(spread)
      total = 0.0
      best = nil
      spread.each do |place, value|
        total += value
        best = place if best.nil? || value > spread[best]
      end
      return nil if total <= 0

      spread[best] / total >= PLACE_AT ? best : nil
    end

    # The worst of +windows+, or nil if there are none.
    def worst(rule, path, windows, source)
      return nil if windows.empty?

      window = windows.max_by(&:probability)
      line = nil
      file = nil
      if rule.directory?
        member = source.members.find { |_member, shown| shown == window.place }
        file = member[0] if member
      elsif window.place
        line = window.place.delete_prefix("L").to_i
      end
      lines = rule.directory? ? nil : [window.first, window.last]
      Verdict.classify(rule, path, window.probability, warn_at: @config.warn_at, lines: lines, line: line, file: file)
    end

    # Each model's answers are cached on their own, so adding a model asks
    # only the new one.
    def cache_key(question, job, client)
      endpoint = client.endpoint
      Cache.key(question.digest, job.state_digest, "#{endpoint.provider}/#{endpoint.model}")
    end
  end
end
