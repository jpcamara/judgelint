# frozen_string_literal: true

module Judgelint
  # Settings from .judgelint.yml, with command-line overrides on top, and the
  # provider's preset under both.
  class Config
    FILE = ".judgelint.yml"
    KEYS = %w[
      provider model api_base path protocol auth api_key_env headers provider_options price_per_million
      rules ignore threshold warn_at window_lines repeat threads batch_size max_state_tokens max_request_tokens
      max_cost_usd full_run_limit timeout retries cache
    ].freeze
    # Settings that belong to one provider. Choosing another provider on the
    # command line drops the file's, so `--provider openai` doesn't ask OpenAI
    # for the file's Jev model.
    PROVIDER_KEYS = %w[
      model api_base path protocol auth api_key_env headers provider_options batch_size price_per_million
    ].freeze

    attr_reader :provider, :model, :api_base, :path, :protocol, :auth, :api_key_env, :headers,
                :provider_options, :price_per_million, :rules_dir, :ignore, :threshold, :warn_at, :window_lines,
                :repeat, :threads, :batch_size, :max_state_tokens, :max_request_tokens, :max_cost_usd,
                :full_run_limit, :timeout, :retries, :cache_path

    def self.load(path: nil, overrides: {})
      data = Judgelint.read_yaml(path || FILE, required: !path.nil?)
      if overrides.key?("provider") && overrides["provider"] != data.fetch("provider", "typesafe").to_s
        data = data.reject { |key, _value| PROVIDER_KEYS.include?(key) }
      end
      new(data.merge(overrides))
    end

    # ${VAR} reads the environment, so a URL can carry an account id. The
    # client expands it when it sends, so commands that make no request don't
    # need every variable set.
    def self.expand(value)
      value.gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}/) do |reference|
        name = reference[2..-2]
        found = ENV.fetch(name, "")
        raise ConfigError, "Set #{name} (used in #{value})" if found.empty?

        found
      end
    end

    def initialize(data)
      unknown = data.keys - KEYS
      raise ConfigError, "#{FILE}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      @data = data
      @provider = data.fetch("provider", "typesafe").to_s
      @preset = PROVIDERS.fetch(@provider, {})
      @model = setting("model")
      @api_base = setting("api_base")
      @path = setting("path") || "/v1/systemone"
      @protocol = setting("protocol") || "system_one"
      @auth = setting("auth") || "bearer"
      @api_key_env = setting("api_key_env")
      @headers = mapping("headers")
      @provider_options = mapping("provider_options")
      @rules_dir = data.fetch("rules", ".judgelint/rules").to_s
      # Files no rule ever judges, and READMEs that are never specs.
      @ignore = list("ignore")
      @threshold = number("threshold", 0.7)
      @warn_at = number("warn_at", 0.4)
      raise ConfigError, "warn_at must be below threshold" unless @warn_at < @threshold

      @price_per_million = price
      @window_lines = count("window_lines", 40)
      @repeat = count("repeat", 1)
      @threads = count("threads", 8)
      @batch_size = count("batch_size", 32)
      # A request's state plus its widest question, and a whole request: Jev's
      # 32k and 64k token limits, with room for the estimate to be off.
      @max_state_tokens = count("max_state_tokens", 30_000)
      @max_request_tokens = count("max_request_tokens", 60_000)
      @max_cost_usd = number("max_cost_usd", 1.0)
      @full_run_limit = count("full_run_limit", 300)
      @timeout = number("timeout", 30)
      @retries = number("retries", 3).to_i
      cache = data.fetch("cache", ".judgelint/cache.json")
      @cache_path = cache == false ? nil : cache.to_s
    end

    def model_label
      "#{provider}/#{model}"
    end

    def api_key
      api_key_env.to_s.empty? ? nil : ENV.fetch(api_key_env, nil)
    end

    # What a preset still needs from you, for `judgelint providers` and errors.
    def needs
      @preset["needs"]
    end

    private

    def setting(key)
      value = @data.key?(key) ? @data[key] : @preset[key]
      value.nil? ? nil : value.to_s
    end

    def list(key)
      value = @data.fetch(key, [])
      value.is_a?(Array) ? value.map(&:to_s) : [value.to_s]
    end

    def mapping(key)
      value = @data.fetch(key, {})
      raise ConfigError, "#{key} must be a mapping" unless value.is_a?(Hash)

      value
    end

    # The preset's price is for its default model; another model has no price
    # unless you set one.
    def price
      return number("price_per_million", 0) if @data.key?("price_per_million")
      return nil unless @preset["price_per_million"] && @model == @preset["model"]

      Judgelint.number(@preset["price_per_million"])
    end

    def count(key, default)
      value = number(key, default).to_i
      raise ConfigError, "#{key} must be at least 1" if value < 1

      value
    end

    def number(key, default)
      # Not fetch(key, default): Spinel miscompiles a Float default on a YAML hash.
      value = @data.key?(key) ? @data[key] : @preset[key]
      number = Judgelint.number(value.nil? ? default : value)
      raise ConfigError, "#{key} must be a number" if number.nil?

      number
    end
  end
end
