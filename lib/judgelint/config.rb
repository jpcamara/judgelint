# frozen_string_literal: true

module Judgelint
  # Settings from .judgelint.yml, with command-line overrides on top, and the
  # provider's preset under both.
  class Config
    FILE = ".judgelint.yml"
    KEYS = %w[
      provider model api_base path protocol auth api_key_env headers provider_options
      rules threshold warn_at max_bytes batch_size timeout retries cache
    ].freeze
    # Settings that belong to one provider. Choosing another provider on the
    # command line drops the file's, so `--provider openai` doesn't ask OpenAI
    # for the file's Jev model.
    PROVIDER_KEYS = %w[model api_base path protocol auth api_key_env headers provider_options batch_size].freeze

    attr_reader :provider, :model, :api_base, :path, :protocol, :auth, :api_key_env, :headers,
                :provider_options, :rules_dir, :threshold, :warn_at, :max_bytes, :batch_size,
                :timeout, :retries, :cache_path

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
      @threshold = number("threshold", 0.7)
      @warn_at = number("warn_at", 0.4)
      raise ConfigError, "warn_at must be below threshold" unless @warn_at < @threshold

      @max_bytes = number("max_bytes", 60_000).to_i
      @batch_size = number("batch_size", 32).to_i
      @timeout = number("timeout", 30)
      @retries = number("retries", 2).to_i
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

    def mapping(key)
      value = @data.fetch(key, {})
      raise ConfigError, "#{key} must be a mapping" unless value.is_a?(Hash)

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
