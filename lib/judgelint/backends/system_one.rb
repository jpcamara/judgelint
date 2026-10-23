# frozen_string_literal: true

module Judgelint
  module Backends
    # Posts rules to a System One endpoint (TypeSafe's Jev, Kev on OpenRouter,
    # Celeris) over Net::HTTP. This is the backend the native binary uses, since
    # Spinel can't load RubyLLM; it sends the same body RubyLLM's TypeSafe
    # provider does.
    class SystemOne
      def initialize(config)
        raise ConfigError, "The system_one backend needs api_base" if config.api_base.to_s.empty?

        @config = config
      end

      # Returns the probability of "yes" for each rule, keyed by question_key.
      def judge(state, rules)
        body = self.class.payload(@config.model, state, rules, @config.provider_options)
        self.class.parse(post(JSON.generate(body)), rules)
      end

      def self.payload(model, state, rules, provider_options)
        questions = {}
        rules.each { |rule| questions[rule.question_key] = question(rule) }
        { "model" => model, "state" => state, "questions" => questions }.merge(provider_options)
      end

      def self.question(rule)
        question = { "type" => "noul", "instructions" => rule.question }
        criteria = {}
        criteria["true"] = rule.yes_means if rule.yes_means
        criteria["false"] = rule.no_means if rule.no_means
        question["criteria"] = criteria unless criteria.empty?
        question
      end

      def self.parse(body, rules)
        answers = JSON.parse(body)["answers"]
        raise BackendError, "Response has no answers: #{body[0, 200]}" unless answers.is_a?(Hash)

        probabilities = {}
        rules.each do |rule|
          answer = answers[rule.question_key]
          value = answer.is_a?(Hash) ? answer["noul"] : nil
          raise BackendError, "No yes/no answer for #{rule.id}: #{answer.inspect}" unless value.is_a?(Numeric)

          probabilities[rule.question_key] = value.to_f
        end
        probabilities
      rescue JSON::ParserError
        raise BackendError, "Response is not JSON: #{body[0, 200]}"
      end

      def self.error_detail(body)
        detail = JSON.parse(body)["detail"]
        detail = detail["message"] if detail.is_a?(Hash)
        detail.to_s.empty? ? body[0, 200] : detail.to_s
      rescue JSON::ParserError
        body[0, 200]
      end

      private

      def post(body)
        uri = URI("#{@config.api_base.delete_suffix('/')}/v1/systemone")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @config.timeout
        http.read_timeout = @config.timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        key = @config.api_key
        request["Authorization"] = "Bearer #{key}" if key
        request.body = body

        response = http.request(request)
        return response.body if response.code.start_with?("2")

        raise BackendError, "#{uri} answered #{response.code}: #{self.class.error_detail(response.body.to_s)}"
      rescue Judgelint::Error
        raise
      rescue StandardError => e
        raise BackendError, "Couldn't reach #{uri}: #{e.message}"
      end
    end
  end
end
