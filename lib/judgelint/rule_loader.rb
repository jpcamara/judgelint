# frozen_string_literal: true

module Judgelint
  # Reads rules from markdown files with YAML frontmatter:
  #
  #   ---
  #   question: Does this code rescue an exception and carry on as if nothing happened?
  #   yes_means: The rescue neither logs, re-raises, nor returns an explicit failure.
  #   no_means: Every rescue logs, re-raises, or turns the error into a result.
  #   paths: ["app/**/*.rb", "lib/**/*.rb"]
  #   ---
  #   Swallowed exceptions hide bugs until they cost us data.
  #
  # The body is the rationale people read. The model sees only the question
  # and the meanings of yes and no.
  module RuleLoader
    FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m
    SEVERITIES = %w[error warning].freeze
    KEYS = %w[id question yes_means no_means fail_when paths excludes severity threshold message].freeze

    def self.load_dir(dir, default_threshold:)
      raise ConfigError, "No rules directory at #{dir} (run `judgelint init`)" unless File.directory?(dir)

      rules = Dir.glob(File.join(dir, "*.md")).sort.map { |path| load_file(path, default_threshold: default_threshold) }
      check_unique(rules)
      rules
    end

    def self.load_file(path, default_threshold:)
      match = FRONTMATTER.match(File.read(path))
      raise ConfigError, "#{path}: rules start with a --- frontmatter block" unless match

      data = parse_yaml(path, match[1])
      unknown = data.keys - KEYS
      raise ConfigError, "#{path}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      question = data["question"].to_s.strip
      raise ConfigError, "#{path}: a rule needs a question" if question.empty?

      body = match[2].strip
      Rule.new(
        id: (data["id"] || File.basename(path, ".md")).to_s,
        question: question,
        yes_means: optional_text(data["yes_means"]),
        no_means: optional_text(data["no_means"]),
        fail_when: answer(path, data.fetch("fail_when", "yes")),
        paths: list(data["paths"], ["**/*"]),
        excludes: list(data["excludes"], []),
        severity: severity(path, data.fetch("severity", "error")),
        threshold: threshold(path, data.key?("threshold") ? data["threshold"] : default_threshold),
        message: (data["message"] || first_paragraph(body) || question).to_s.strip,
        source: path
      )
    end

    def self.parse_yaml(path, yaml)
      data = YAML.safe_load(yaml)
      data = {} if data.nil?
      raise ConfigError, "#{path}: frontmatter must be a mapping" unless data.is_a?(Hash)

      data
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    # YAML reads a bare yes/no as true/false.
    def self.answer(path, value)
      value = "yes" if value == true
      value = "no" if value == false
      value = value.to_s
      raise ConfigError, "#{path}: fail_when is yes or no, not #{value}" unless %w[yes no].include?(value)

      value
    end

    def self.severity(path, value)
      value = value.to_s
      raise ConfigError, "#{path}: severity is error or warning, not #{value}" unless SEVERITIES.include?(value)

      value
    end

    def self.threshold(path, value)
      number = number(value)
      raise ConfigError, "#{path}: threshold must be a number, not #{value}" if number.nil?
      raise ConfigError, "#{path}: threshold must be between 0 and 1" unless number.positive? && number <= 1

      number
    end

    NUMBER = /\A-?\d+(?:\.\d+)?\z/

    # Float(), without the rescue: answers nil for anything that isn't a number.
    def self.number(value)
      string = value.to_s.strip
      NUMBER.match?(string) ? string.to_f : nil
    end

    def self.list(value, default)
      return default if value.nil?
      return value.map(&:to_s) if value.is_a?(Array)

      [value.to_s]
    end

    def self.optional_text(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def self.first_paragraph(body)
      paragraph = body.split(/\n\s*\n/).map(&:strip).find { |part| !part.empty? && !part.start_with?("#") }
      paragraph&.gsub(/\s*\n\s*/, " ")
    end

    def self.check_unique(rules)
      rules.group_by(&:question_key).each_value do |same|
        next if same.size == 1

        raise ConfigError, "Rule ids collide: #{same.map(&:id).join(', ')}"
      end
    end
  end
end
