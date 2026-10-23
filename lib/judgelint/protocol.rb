# frozen_string_literal: true

module Judgelint
  # The two request shapes decision models are served with. judgelint asks only
  # yes/no questions, so each renders a Question as that protocol's yes/no
  # type and reads back the probability of yes. A nil probability is a refusal.
  module Protocol
    # TypeSafe's System One: questions keyed by name, yes/no is "noul".
    module SystemOne
      def self.payload(model, state, questions)
        rendered = {}
        questions.each { |question| rendered[question.key] = render(question) }
        body = { "state" => state, "questions" => rendered }
        body["model"] = model unless model.to_s.empty?
        body
      end

      def self.render(question)
        rendered = { "type" => "noul", "instructions" => question.instructions }
        criteria = {}
        criteria["true"] = question.yes_means if question.yes_means
        criteria["false"] = question.no_means if question.no_means
        rendered["criteria"] = criteria unless criteria.empty?
        rendered
      end

      def self.parse(data, questions)
        answers = data["answers"]
        raise ApiError, "Response has no answers: #{JSON.generate(data)[0, 200]}" unless answers.is_a?(Hash)

        probabilities = {}
        questions.each do |question|
          probabilities[question.key] = Protocol.probability(answers[question.key], "noul", question)
        end
        probabilities
      end
    end

    # OpenAI's Decisions API: questions are a list with names, yes/no is
    # "predicate" with no criteria field, and answers come back as a list.
    module Decisions
      # Decisions' input is text, so a structured state goes as its JSON.
      def self.payload(model, state, questions)
        input = state.is_a?(String) ? state : JSON.generate(state)
        { "model" => model, "input" => input, "questions" => questions.map { |question| render(question) } }
      end

      # Criteria become lines of the instructions, as RubyLLM and LiteLLM do.
      def self.render(question)
        lines = [question.instructions]
        lines << "Yes: #{question.yes_means}" if question.yes_means
        lines << "No: #{question.no_means}" if question.no_means
        { "type" => "predicate", "name" => question.key, "instructions" => lines.join("\n") }
      end

      def self.parse(data, questions)
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
        questions.each do |question|
          answer = by_name.key?(question.key) ? by_name[question.key] : unnamed.shift
          probabilities[question.key] = Protocol.probability(answer, "probability", question)
        end
        probabilities
      end
    end

    ALL = { "system_one" => SystemOne, "decisions" => Decisions }.freeze

    def self.probability(answer, field, question)
      return nil if answer.is_a?(Hash) && answer["type"] == "refusal"

      value = answer.is_a?(Hash) ? answer[field] : nil
      raise ApiError, "No yes/no answer for #{question.key}: #{answer.inspect}" unless value.is_a?(Numeric)

      value.to_f
    end
  end
end
