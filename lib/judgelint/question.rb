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
      return convention_instructions if rule.convention

      text = rule.window? ? "Look at lines #{first}-#{last} of the file; the rest is context. #{rule.question}" : rule.question
      return text unless rule.fail_when == "yes"

      scope = { "window" => "those lines do it", "file" => "the code does it", "directory" => "the files do it" }
              .fetch(rule.scope)
      "#{text} Answer yes only when #{scope}, not when the question doesn't apply."
    end

    # A spec's bullet, asked as written.
    def convention_instructions
      ask =
        case rule.scope
        when "window"
          "Do lines #{first}-#{last} of the file (the rest is context) break this convention? Answer yes only " \
            "when those lines clearly break it, not when it doesn't apply to them."
        when "file"
          "Does this file break this convention? Answer yes only when the file clearly breaks it, not when it " \
            "doesn't apply to the file."
        else
          "Do the files in this directory break this convention? Answer yes only when they clearly break it, " \
            "not when it doesn't apply to them."
        end
      "#{ask} Convention: #{rule.convention}"
    end

    # A convention gets the criteria a question would spell out by hand.
    def yes_means
      rule.yes_means || (rule.convention && "The code clearly breaks the convention.")
    end

    def no_means
      rule.no_means || (rule.convention && "The code follows the convention, or the convention doesn't apply to it.")
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(JSON.generate([instructions, yes_means.to_s, no_means.to_s]))
    end
  end
end
