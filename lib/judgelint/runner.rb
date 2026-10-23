# frozen_string_literal: true

module Judgelint
  # Judges files against the rules that govern them. Each file is one model
  # request carrying every applicable rule as its own question, so a file's
  # verdicts never depend on which other files ran alongside it.
  class Runner
    def initialize(config:, rules:, backend:, cache:)
      @config = config
      @rules = rules
      @backend = backend
      @cache = cache
    end

    def run(paths)
      paths.flat_map { |path| judge_file(path, @rules.select { |rule| rule.applies_to?(path) }) }
    ensure
      @cache.save
    end

    # Judges one file against the given rules, whether or not they target it.
    # +shown_as+ is the path the model sees, which fixtures use to keep their
    # pass/ or fail/ directory out of the question.
    def judge_file(path, rules, shown_as: path)
      return [] if rules.empty?

      content = File.read(path)
      if content.bytesize > @config.max_bytes
        return rules.map { |rule| Verdict.new(rule: rule, path: path, probability: nil, status: :skipped) }
      end

      probabilities = answer(shown_as, content, rules)
      rules.map do |rule|
        Verdict.classify(rule, path, probabilities.fetch(rule.question_key), warn_at: @config.warn_at)
      end
    end

    def self.state(path, content)
      "Path: #{path}\n\n#{content}"
    end

    private

    def answer(path, content, rules)
      state = self.class.state(path, content)
      probabilities = {}
      missing = []
      rules.each do |rule|
        cached = @cache.fetch(cache_key(rule, state))
        if cached
          probabilities[rule.question_key] = cached
        else
          missing << rule
        end
      end

      missing.each_slice(@config.batch_size) do |batch|
        answers = @backend.judge(state, batch)
        batch.each do |rule|
          probability = answers.fetch(rule.question_key)
          @cache.store(cache_key(rule, state), probability)
          probabilities[rule.question_key] = probability
        end
      end
      probabilities
    end

    def cache_key(rule, state)
      Cache.key(rule, state, @config.model_label)
    end
  end
end
