# frozen_string_literal: true

module Judgelint
  # Judges files against the rules that govern them, and rules against their
  # examples. Each file is one model request carrying every applicable rule as
  # its own question, so a file's verdicts never depend on which other files
  # ran alongside it.
  class Runner
    def initialize(config:, rules:, client:, cache:)
      @config = config
      @rules = rules
      @client = client
      @cache = cache
    end

    def run(paths)
      paths.flat_map { |path| judge_file(path, @rules.select { |rule| rule.applies_to?(path) }) }
    ensure
      @cache.save
    end

    # Files under rules/<id>/pass must not be judged violations, files under
    # rules/<id>/fail must. The model sees each example's path relative to its
    # pass/ or fail/ directory, so the directory never gives the answer away.
    def examples
      @rules.flat_map do |rule|
        %i[pass fail].flat_map do |expected|
          dir = File.join(rule.examples_dir, expected.to_s)
          Glob.expand([File.join(dir, "**", "*")]).map do |path|
            judge_file(path, [rule], shown_as: path.delete_prefix("#{dir}/")).first.as_example(expected)
          end
        end
      end
    ensure
      @cache.save
    end

    private

    def judge_file(path, rules, shown_as: path)
      return [] if rules.empty?

      content = File.read(path)
      if content.bytesize > @config.max_bytes
        return rules.map { |rule| Verdict.new(rule: rule, path: path, probability: nil, status: :skipped) }
      end

      probabilities = answer(shown_as, content, rules)
      rules.map do |rule|
        probability = probabilities[rule.question_key]
        if probability.nil?
          Verdict.new(rule: rule, path: path, probability: nil, status: :refused)
        else
          Verdict.classify(rule, path, probability, warn_at: @config.warn_at)
        end
      end
    end

    def answer(path, content, rules)
      state = "Path: #{path}\n\n#{content}"
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
        answers = @client.judge(state, batch)
        batch.each do |rule|
          probability = answers[rule.question_key]
          @cache.store(cache_key(rule, state), probability) unless probability.nil?
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
