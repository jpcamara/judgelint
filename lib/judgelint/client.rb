# frozen_string_literal: true

module Judgelint
  # Asks one model (an Endpoint) the questions over Net::HTTP, in whichever
  # protocol its provider speaks. Plain Net::HTTP rather than a gem keeps the
  # same code compiling with Spinel.
  class Client
    RETRY_STATUSES = %w[408 429 500 502 503 504 529].freeze
    # The native binary links OpenSSL statically, so it looks for certificates
    # where OpenSSL was built. Unless SSL_CERT_FILE says otherwise, it uses the
    # system's bundle: macOS and Alpine, Debian and Ubuntu, then Fedora and RHEL.
    CA_BUNDLES = %w[/etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt].freeze

    attr_reader :usage, :endpoint

    def initialize(endpoint, usage: Usage.new, sleeper: ->(seconds) { sleep(seconds) })
      if RUBY_ENGINE == "spinel" && ENV.fetch("SSL_CERT_FILE", "").empty?
        bundle = CA_BUNDLES.find { |path| File.file?(path) }
        ENV["SSL_CERT_FILE"] = bundle if bundle
      end
      @endpoint = endpoint
      @protocol = Protocol::ALL.fetch(endpoint.protocol) do
        raise ConfigError, "protocol is system_one or decisions, not #{endpoint.protocol}"
      end
      @usage = usage
      @sleeper = sleeper
      check_settings
    end

    # Returns the probability of "yes" for each question, keyed by its key,
    # or nil for a question the model refused.
    def judge(state, questions)
      data = self.class.unwrap(post(JSON.generate(payload(state, questions))))
      @usage.record(data, @endpoint.price_per_million)
      @protocol.parse(data, questions)
    end

    def payload(state, questions)
      @protocol.payload(@endpoint.model, state, questions).merge(@endpoint.provider_options)
    end

    # A conservative token count for code: three bytes a token.
    def tokens(state, questions)
      JSON.generate(payload(state, questions)).bytesize / 3
    end

    # What one more question adds to a request, without serializing the file again.
    def question_tokens(question)
      (JSON.generate(@protocol.render(question)).bytesize + question.key.bytesize + 6) / 3
    end

    def url
      base = Config.expand(@endpoint.api_base)
      path = Config.expand(@endpoint.path).gsub("{model}", @endpoint.model.to_s)
      "#{base.delete_suffix('/')}/#{path.delete_prefix('/')}"
    end

    # Cloudflare wraps the answers as {result: {...}, success, errors}.
    def self.unwrap(data)
      raise ApiError, "Response is not a JSON object" unless data.is_a?(Hash)

      result = data["result"]
      !data.key?("answers") && result.is_a?(Hash) && result.key?("answers") ? result : data
    end

    # The error message, whichever of the shapes providers use: TypeSafe's
    # detail (a string, {message}, or a validation list), OpenAI's
    # {error: {message}}, Cloudflare's errors list, or a bare message.
    def self.error_detail(body)
      data = JSON.parse(body)
      return body[0, 200] unless data.is_a?(Hash)

      detail = data["detail"] || data["error"] || data["errors"] || data["message"]
      message(detail) || body[0, 200]
    rescue JSON::ParserError
      body[0, 200]
    end

    def self.message(detail)
      case detail
      when String then detail.empty? ? nil : detail
      when Hash then message(detail["message"] || detail["msg"])
      when Array
        messages = detail.map { |item| message(item) }.compact
        messages.empty? ? nil : messages.join("; ")
      end
    end

    # Called before the first request, so a run the cache answers needs no key.
    def check_key
      raise ConfigError, "Set #{@endpoint.api_key_env} to your #{@endpoint.provider} API key" if key_missing?
    end

    private

    def check_settings
      provider = @endpoint.provider
      if @endpoint.api_base.to_s.empty?
        raise ConfigError, "Provider #{provider} needs #{@endpoint.needs || 'api_base'} in .judgelint.yml"
      end
      raise ConfigError, "Provider #{provider} needs a model in .judgelint.yml" if model_needed?

      unless %w[bearer basic none].include?(@endpoint.auth) || @endpoint.auth.start_with?("header:")
        raise ConfigError, "auth is bearer, basic, none, or header:<name>, not #{@endpoint.auth}"
      end
    end

    # llama.cpp serves one model and doesn't need its name; nothing else can guess it.
    def model_needed?
      @endpoint.model.to_s.empty? && @endpoint.provider != "llamacpp"
    end

    def key_missing?
      @endpoint.auth != "none" && !@endpoint.api_key_env.to_s.empty? && @endpoint.api_key.to_s.empty?
    end

    def post(body)
      attempt = 0
      loop do
        attempt += 1
        response = request(body, attempt)
        next if response.nil?

        code = response.code
        return parse_json(response.body.to_s) if code.start_with?("2")

        detail = self.class.error_detail(response.body.to_s)
        if RETRY_STATUSES.include?(code) && attempt <= Endpoint::RETRIES
          @sleeper.call(retry_delay(response, attempt))
          next
        end
        raise ApiError, "#{@endpoint.label} answered #{code}: #{detail}"
      end
    end

    # Answers nil after a connection error that's worth another try.
    def request(body, attempt)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = Endpoint::TIMEOUT
      http.read_timeout = Endpoint::TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      authorize(request)
      @endpoint.headers.each { |name, value| request[name.to_s] = Config.expand(value.to_s) }
      request.body = body
      http.request(request)
    rescue Judgelint::Error
      raise
    rescue StandardError => e
      # Nothing listening isn't going to change in a few seconds; a dropped or
      # stalled connection might.
      refused = e.is_a?(Errno::ECONNREFUSED) || e.message.include?("Connection refused")
      raise ApiError, "Couldn't reach #{@endpoint.label} at #{url}: #{e.message}" if refused || attempt > Endpoint::RETRIES

      @sleeper.call(2.0**attempt)
      nil
    end

    def authorize(request)
      key = @endpoint.api_key
      return if key.to_s.empty?

      case @endpoint.auth
      when "bearer" then request["Authorization"] = "Bearer #{key}"
      when "basic" then request["Authorization"] = "Basic #{["token:#{key}"].pack("m0")}"
      when "none" then nil
      else request[@endpoint.auth.delete_prefix("header:")] = key
      end
    end

    def retry_delay(response, attempt)
      after = Judgelint.number(response["Retry-After"])
      after ? [after, 30.0].min : 0.5 * (2**(attempt - 1))
    end

    def parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      raise ApiError, "#{@endpoint.label} answered with something other than JSON: #{body[0, 200]}"
    end
  end
end
