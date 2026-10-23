# frozen_string_literal: true

module Judgelint
  # One rule asked about one range of a file. The model sees the whole file;
  # the question points at the lines.
  #
  # A spec's bullet is asked twice: whether the code breaks it, and, with the
  # answer flipped, whether the code follows it. Decision models lean toward
  # no on the first and yes on the second, so the average is steadier than
  # either.
  class Question
    BREAKS = "The code clearly breaks the rule."
    FOLLOWS = "The code follows the rule, or the rule doesn't apply to it."

    attr_reader :rule, :first, :last

    def initialize(rule, first, last, inverted: false)
      @rule = rule
      @first = first
      @last = last
      @inverted = inverted
    end

    def key
      base = "#{rule.question_key}.#{first}-#{last}"
      return base unless rule.convention

      @inverted ? "#{base}.follows" : "#{base}.breaks"
    end

    # The probability the code breaks the rule, from the probability of yes.
    def violation(yes_probability)
      @inverted ? 1.0 - yes_probability : rule.violation_probability(yes_probability)
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

    def yes_means
      return rule.yes_means unless rule.convention

      @inverted ? rule.no_means || FOLLOWS : rule.yes_means || BREAKS
    end

    def no_means
      return rule.no_means unless rule.convention

      @inverted ? rule.yes_means || BREAKS : rule.no_means || FOLLOWS
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(JSON.generate([instructions, yes_means.to_s, no_means.to_s]))
    end

    private

    # The spec's prose is in the state as team_rules, so the bullet is "the
    # following team rule".
    def convention_instructions
      ask =
        case rule.scope
        when "window"
          if @inverted
            "Do lines #{first}-#{last} of the file follow the following team rule, or does it not apply to them? " \
              "Answer false only when those lines clearly break it."
          else
            "Do lines #{first}-#{last} of the file clearly violate the following team rule? Answer true only " \
              "when the code breaks the rule, not when the rule does not apply to it."
          end
        when "file"
          if @inverted
            "Does the file follow the following team rule, or does it not apply to it? Answer false only when " \
              "the file clearly breaks it."
          else
            "Does the file clearly violate the following team rule? Answer true only when the code breaks the " \
              "rule, not when the rule does not apply to it."
          end
        else
          if @inverted
            "Do the files follow the following team rule, or does it not apply to them? Answer false only when " \
              "they clearly break it."
          else
            "Do the files clearly violate the following team rule? Answer true only when the code breaks the " \
              "rule, not when the rule does not apply to it."
          end
        end
      "#{ask} Rule: #{rule.convention}"
    end
  end
end
