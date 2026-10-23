# frozen_string_literal: true

module Judgelint
  # One convention, asked of a file as a single yes/no question. Rules are
  # markdown files with YAML frontmatter:
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
  # and the meanings of yes and no. +fail_when+ is the answer that means the
  # file breaks the convention, so a rule can ask "Does this rescue and discard
  # an exception?" (fail on yes) or "Does this service validate its input
  # first?" (fail on no).
  #
  # +scope+ "window" asks about each range of lines, so a finding says where
  # it is; "file" asks once about the whole file, for conventions no range can
  # show on its own; "directory" asks once about each directory its paths
  # match, with all of the directory's files, for conventions about how files
  # relate. A fail_when: no rule is about the whole file by default.
  #
  # +context+ globs name files the model reads alongside, such as shared
  # types, which are never judged themselves.
  class Rule
    FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m
    KEYS = %w[id question convention yes_means no_means fail_when scope paths excludes context severity threshold message].freeze

    attr_reader :id, :question, :convention, :yes_means, :no_means, :fail_when, :scope, :paths, :excludes,
                :context, :severity, :threshold, :message, :source, :examples_dir, :prose

    # The rules in +dir+ alone (Spec.discover also finds READMEs).
    def self.load_dir(dir, default_threshold:)
      Spec.discover(rules_dir: dir, default_threshold: default_threshold, readmes: false)
    end

    # A rule is a question asked exactly as written, or a convention (a
    # spec's bullet) asked whether the code breaks it.
    # +prose+ is a spec's body, which the model reads alongside the file.
    def initialize(data, source:, body: "", default_threshold: 0.7, examples_dir: nil, prose: nil)
      unknown = data.keys - KEYS
      raise ConfigError, "#{source}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      @source = source
      @id = (data["id"] || File.basename(source, ".md")).to_s
      @question = text(data["question"])
      @convention = text(data["convention"])
      raise ConfigError, "#{source}: a rule needs a question" if @question.nil? && @convention.nil?

      @examples_dir = examples_dir || source.delete_suffix(".md")
      @prose = prose
      @yes_means = text(data["yes_means"])
      @no_means = text(data["no_means"])
      @fail_when = one_of("fail_when", yes_or_no(data.fetch("fail_when", "yes")), %w[yes no])
      @scope = one_of("scope", data.fetch("scope", @fail_when == "yes" ? "window" : "file"), %w[window file directory])
      @severity = one_of("severity", data.fetch("severity", "error"), %w[error warning])
      @paths = list(data["paths"], ["**/*"])
      @excludes = list(data["excludes"], [])
      @context = list(data["context"], [])
      @threshold = parse_threshold(data.key?("threshold") ? data["threshold"] : default_threshold)
      @message = (data["message"] || first_paragraph(body) || @question || @convention).to_s.strip
    end

    def applies_to?(path)
      Glob.match_any?(paths, path) && !Glob.match_any?(excludes, path)
    end

    def question_key
      id.gsub(/[^A-Za-z0-9_]/, "_")
    end

    def window?
      scope == "window"
    end

    def directory?
      scope == "directory"
    end

    def context_files
      Glob.expand(context)
    end

    # The directories a directory rule governs.
    def directories
      paths.flat_map { |pattern| Dir.glob(pattern) }.select { |path| File.directory?(path) && applies_to?(path) }.uniq.sort
    end

    # The ranges to ask about: windows of +size+ lines, or the whole file.
    def ranges(source, size)
      window? ? source.windows(size) : [[1, source.line_count]].reject { |_first, last| last.zero? }
    end

    def violation_probability(yes_probability)
      fail_when == "yes" ? yes_probability : 1.0 - yes_probability
    end

    def error?
      severity == "error"
    end

    private

    # YAML reads a bare yes/no as true/false.
    def yes_or_no(value)
      return "yes" if value == true
      return "no" if value == false

      value
    end

    def one_of(key, value, allowed)
      value = value.to_s
      raise ConfigError, "#{source}: #{key} is #{allowed.join(' or ')}, not #{value}" unless allowed.include?(value)

      value
    end

    def parse_threshold(value)
      number = Judgelint.number(value)
      raise ConfigError, "#{source}: threshold must be a number, not #{value}" if number.nil?
      raise ConfigError, "#{source}: threshold must be between 0 and 1" unless number.positive? && number <= 1

      number
    end

    def list(value, default)
      return default if value.nil?

      value.is_a?(Array) ? value.map(&:to_s) : [value.to_s]
    end

    def text(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def first_paragraph(body)
      paragraph = body.split(/\n\s*\n/).map(&:strip).find { |part| !part.empty? && !part.start_with?("#") }
      paragraph&.gsub(/\s*\n\s*/, " ")
    end
  end
end
