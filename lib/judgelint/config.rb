# frozen_string_literal: true

module Judgelint
  # Settings from .judgelint.yml, with command-line overrides on top.
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Config
    attr_reader :provider, :model, :api_base, :path, :protocol, :auth, :api_key_env, :headers,
                :provider_options, :rules_dir, :threshold, :warn_at, :max_bytes, :batch_size,
                :timeout, :retries, :cache_path

    def initialize(provider:, model:, api_base:, path:, protocol:, auth:, api_key_env:, headers:,
                   provider_options:, rules_dir:, threshold:, warn_at:, max_bytes:, batch_size:,
                   timeout:, retries:, cache_path:)
      @provider = provider
      @model = model
      @api_base = api_base
      @path = path
      @protocol = protocol
      @auth = auth
      @api_key_env = api_key_env
      @headers = headers
      @provider_options = provider_options
      @rules_dir = rules_dir
      @threshold = threshold
      @warn_at = warn_at
      @max_bytes = max_bytes
      @batch_size = batch_size
      @timeout = timeout
      @retries = retries
      @cache_path = cache_path
    end

    def model_label
      "#{provider}/#{model}"
    end

    def api_key
      api_key_env.to_s.empty? ? nil : ENV.fetch(api_key_env, nil)
    end
  end

  module ConfigLoader
    FILE = ".judgelint.yml"
    KEYS = %w[
      provider model api_base path protocol auth api_key_env headers provider_options
      rules threshold warn_at max_bytes batch_size timeout retries cache
    ].freeze

    # Settings that belong to one provider. Choosing another provider on the
    # command line drops the file's, so `--provider openai` doesn't ask OpenAI
    # for the file's Jev model.
    PROVIDER_KEYS = %w[model api_base path protocol auth api_key_env headers provider_options batch_size].freeze

    def self.load(path: nil, overrides: {})
      data = read(path || FILE, required: !path.nil?)
      if overrides.key?("provider") && overrides["provider"] != data.fetch("provider", "typesafe").to_s
        data = data.reject { |key, _value| PROVIDER_KEYS.include?(key) }
      end
      data = data.merge(overrides)
      unknown = data.keys - KEYS
      raise ConfigError, "#{path || FILE}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      build(data)
    end

    def self.read(path, required:)
      unless File.exist?(path)
        raise ConfigError, "No config file at #{path}" if required

        return {}
      end

      data = YAML.safe_load(File.read(path))
      data = {} if data.nil?
      raise ConfigError, "#{path} must be a mapping" unless data.is_a?(Hash)

      data
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def self.build(data)
      provider = data.fetch("provider", "typesafe").to_s
      preset = PROVIDERS.fetch(provider, {})
      threshold = number(data, preset, "threshold", 0.7)
      warn_at = number(data, preset, "warn_at", 0.4)
      raise ConfigError, "warn_at must be below threshold" unless warn_at < threshold

      Config.new(
        provider: provider,
        model: setting(data, preset, "model"),
        api_base: setting(data, preset, "api_base"),
        path: setting(data, preset, "path") || "/v1/systemone",
        protocol: setting(data, preset, "protocol") || "system_one",
        auth: setting(data, preset, "auth") || "bearer",
        api_key_env: setting(data, preset, "api_key_env"),
        headers: mapping(data, "headers"),
        provider_options: mapping(data, "provider_options"),
        rules_dir: data.fetch("rules", ".judgelint/rules").to_s,
        threshold: threshold,
        warn_at: warn_at,
        max_bytes: number(data, preset, "max_bytes", 60_000).to_i,
        batch_size: number(data, preset, "batch_size", 32).to_i,
        timeout: number(data, preset, "timeout", 30),
        retries: number(data, preset, "retries", 2).to_i,
        cache_path: cache_path(data)
      )
    end

    def self.setting(data, preset, key)
      value = data.key?(key) ? data[key] : preset[key]
      value.nil? ? nil : value.to_s
    end

    def self.mapping(data, key)
      value = data.fetch(key, {})
      raise ConfigError, "#{key} must be a mapping" unless value.is_a?(Hash)

      value
    end

    # ${VAR} reads the environment, so a URL can carry an account id. The
    # client expands it when it sends, so commands that make no request don't
    # need every variable set.
    def self.expand(value)
      return nil if value.nil?

      value.gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}/) do |reference|
        name = reference[2..-2]
        found = ENV.fetch(name, "")
        raise ConfigError, "Set #{name} (used in #{value})" if found.empty?

        found
      end
    end

    def self.number(data, preset, key, default)
      # Not fetch(key, default): Spinel miscompiles a Float default on a YAML hash.
      value = data.key?(key) ? data[key] : preset[key]
      number = RuleLoader.number(value.nil? ? default : value)
      raise ConfigError, "#{key} must be a number" if number.nil?

      number
    end

    # `cache: false` turns the cache off.
    def self.cache_path(data)
      value = data.fetch("cache", ".judgelint/cache.json")
      value == false ? nil : value.to_s
    end
  end
end
