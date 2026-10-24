# frozen_string_literal: true

module Judgelint
  # The two request shapes decision models are served with. Each renders a
  # Question as a yes/no question or a choice, and reads back the probability
  # of yes, or a choice's probabilities as {option => probability}. A nil
  # answer is a refusal.
  module Protocol
    # TypeSafe's System One: questions keyed by name, yes/no is "noul", and a
    # choice's options are its criteria.
    module SystemOne
      def self.payload(model, state, questions)
        rendered = {}
        questions.each { |question| rendered[question.key] = render(question) }
        body = { "state" => state, "questions" => rendered }
        body["model"] = model unless model.to_s.empty?
        body
      end

      def self.render(question)
        return { "type" => "choice", "instructions" => question.instructions, "criteria" => question.options } if question.choice?

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
          answer = answers[question.key]
          probabilities[question.key] =
            question.choice? ? Protocol.distribution(answer, answer.is_a?(Hash) ? answer["probabilities"] : nil, question)
                             : Protocol.probability(answer, "noul", question)
        end
        probabilities
      end
    end

    # OpenAI's Decisions API: questions are a list with names, yes/no is
    # "predicate" with no criteria field, a choice lists its options as
    # {value, description}, and answers come back as a list.
    module Decisions
      # Decisions' input is text, so a structured state goes as its JSON.
      def self.payload(model, state, questions)
        input = state.is_a?(String) ? state : JSON.generate(state)
        { "model" => model, "input" => input, "questions" => questions.map { |question| render(question) } }
      end

      # A yes/no question's criteria become lines of its instructions, as
      # RubyLLM and LiteLLM do.
      def self.render(question)
        if question.choice?
          choices = question.options.map do |value, description|
            description ? { "value" => value, "description" => description } : { "value" => value }
          end
          return { "type" => "choice", "name" => question.key, "instructions" => question.instructions, "choices" => choices }
        end

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
          probabilities[question.key] =
            question.choice? ? Protocol.distribution(answer, listed(answer), question) : Protocol.probability(answer, "probability", question)
        end
        probabilities
      end

      # [{value, probability}] as {value => probability}.
      def self.listed(answer)
        list = answer.is_a?(Hash) ? answer["probabilities"] : nil
        return nil unless list.is_a?(Array)

        list.to_h { |entry| [entry["value"].to_s, entry["probability"]] }
      end
    end

    ALL = { "system_one" => SystemOne, "decisions" => Decisions }.freeze

    def self.probability(answer, field, question)
      return nil if answer.is_a?(Hash) && answer["type"] == "refusal"

      value = answer.is_a?(Hash) ? answer[field] : nil
      raise ApiError, "No yes/no answer for #{question.key}: #{answer.inspect}" unless value.is_a?(Numeric)

      value.to_f
    end

    def self.distribution(answer, probabilities, question)
      return nil if answer.is_a?(Hash) && answer["type"] == "refusal"
      raise ApiError, "No choice answer for #{question.key}: #{answer.inspect}" unless probabilities.is_a?(Hash)

      found = {}
      question.options.each_key { |option| found[option] = probabilities[option].to_f }
      found
    end
  end
end
