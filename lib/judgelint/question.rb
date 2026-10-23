# frozen_string_literal: true

module Judgelint
  # One rule asked about one range of a file. The model sees the whole file;
  # the question points at the lines.
  class Question
    attr_reader :rule, :first, :last

    def initialize(rule, first, last)
      @rule = rule
      @first = first
      @last = last
    end

    def key
      "#{rule.question_key}.#{first}-#{last}"
    end

    # "Answer yes only when..." keeps the model from flagging code the rule
    # doesn't cover.
    def instructions
      text = rule.window? ? "Look at lines #{first}-#{last} of the file; the rest is context. #{rule.question}" : rule.question
      return text unless rule.fail_when == "yes"

      scope = rule.window? ? "those lines do it" : "the code does it"
      "#{text} Answer yes only when #{scope}, not when the question doesn't apply."
    end

    def yes_means
      rule.yes_means
    end

    def no_means
      rule.no_means
    end

    def digest
      Digest::SHA256.hexdigest(JSON.generate([instructions, yes_means.to_s, no_means.to_s]))
    end
  end
end
