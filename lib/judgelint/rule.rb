# frozen_string_literal: true

module Judgelint
  # One convention, asked of a file as a single yes/no question.
  #
  # +fail_when+ is the answer that means the file breaks the convention, so a
  # rule can ask "Does this rescue and discard an exception?" (fail on yes) or
  # "Does this service validate its input first?" (fail on no).
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Rule
    attr_reader :id, :question, :yes_means, :no_means, :fail_when, :paths, :excludes, :severity, :threshold, :message, :source

    def initialize(id:, question:, yes_means:, no_means:, fail_when:, paths:, excludes:, severity:, threshold:, message:, source:)
      @id = id
      @question = question
      @yes_means = yes_means
      @no_means = no_means
      @fail_when = fail_when
      @paths = paths
      @excludes = excludes
      @severity = severity
      @threshold = threshold
      @message = message
      @source = source
    end

    def applies_to?(path)
      Glob.match_any?(paths, path) && !Glob.match_any?(excludes, path)
    end

    def question_key
      id.gsub(/[^A-Za-z0-9_]/, "_")
    end

    def violation_probability(yes_probability)
      fail_when == "yes" ? yes_probability : 1.0 - yes_probability
    end

    # Changes whenever anything the model is shown for this rule changes.
    def digest
      Digest::SHA256.hexdigest(JSON.generate([question, yes_means.to_s, no_means.to_s]))
    end

    # Example files live beside the rule: rules/<id>/pass/* and rules/<id>/fail/*.
    def examples_dir
      source.delete_suffix(".md")
    end

    def error?
      severity == "error"
    end
  end
end
