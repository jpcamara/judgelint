# frozen_string_literal: true

module Judgelint
  # The two request shapes decision models are served with. judgelint asks only
  # yes/no questions, so each renders a rule as that protocol's yes/no type
  # and reads back the probability of yes. A nil probability is a refusal.
  module Protocol
    def self.for(name)
      case name
      when "system_one" then SystemOne
      when "decisions" then Decisions
      else raise ConfigError, "protocol is system_one or decisions, not #{name}"
      end
    end

    # TypeSafe's System One: questions keyed by name, yes/no is "noul".
    module SystemOne
      def self.payload(model, state, rules)
        questions = {}
        rules.each { |rule| questions[rule.question_key] = question(rule) }
        body = { "state" => state, "questions" => questions }
        body["model"] = model unless model.to_s.empty?
        body
      end

      def self.question(rule)
        question = { "type" => "noul", "instructions" => rule.question }
        criteria = {}
        criteria["true"] = rule.yes_means if rule.yes_means
        criteria["false"] = rule.no_means if rule.no_means
        question["criteria"] = criteria unless criteria.empty?
        question
      end

      def self.parse(data, rules)
        answers = data["answers"]
        raise ApiError, "Response has no answers: #{JSON.generate(data)[0, 200]}" unless answers.is_a?(Hash)

        probabilities = {}
        rules.each do |rule|
          probabilities[rule.question_key] = Protocol.probability(answers[rule.question_key], "noul", rule)
        end
        probabilities
      end
    end

    # OpenAI's Decisions API: questions are a list with names, yes/no is
    # "predicate" with no criteria field, and answers come back as a list.
    module Decisions
      def self.payload(model, state, rules)
        questions = rules.map do |rule|
          { "type" => "predicate", "name" => rule.question_key, "instructions" => instructions(rule) }
        end
        { "model" => model, "input" => state, "questions" => questions }
      end

      # Criteria become lines of the instructions, as RubyLLM and LiteLLM do.
      def self.instructions(rule)
        lines = [rule.question]
        lines << "Yes: #{rule.yes_means}" if rule.yes_means
        lines << "No: #{rule.no_means}" if rule.no_means
        lines.join("\n")
      end

      def self.parse(data, rules)
        answers = data["answers"]
        raise ApiError, "Response has no answers: #{JSON.generate(data)[0, 200]}" unless answers.is_a?(Array)

        # Answers come back in question order; match by name when there is
        # one, and give unnamed answers to the remaining questions in order.
        by_name = {}
        unnamed = []
        answers.each do |answer|
          name = answer.is_a?(Hash) ? answer["name"].to_s : ""
          name.empty? ? unnamed << answer : by_name[name] = answer
        end
        probabilities = {}
        rules.each do |rule|
          answer = by_name.key?(rule.question_key) ? by_name[rule.question_key] : unnamed.shift
          probabilities[rule.question_key] = Protocol.probability(answer, "probability", rule)
        end
        probabilities
      end
    end

    def self.probability(answer, field, rule)
      return nil if answer.is_a?(Hash) && answer["type"] == "refusal"

      value = answer.is_a?(Hash) ? answer[field] : nil
      raise ApiError, "No yes/no answer for #{rule.id}: #{answer.inspect}" unless value.is_a?(Numeric)

      value.to_f
    end
  end
end
