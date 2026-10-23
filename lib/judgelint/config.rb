# frozen_string_literal: true

module Judgelint
  # Settings from .judgelint.yml, with command-line overrides on top.
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Config
    attr_reader :provider, :model, :api_base, :api_key_env, :provider_options, :rules_dir, :threshold, :warn_at, :max_bytes, :batch_size, :timeout, :cache_path

    def initialize(provider:, model:, api_base:, api_key_env:, provider_options:, rules_dir:, threshold:, warn_at:, max_bytes:, batch_size:, timeout:, cache_path:)
      @provider = provider
      @model = model
      @api_base = api_base
      @api_key_env = api_key_env
      @provider_options = provider_options
      @rules_dir = rules_dir
      @threshold = threshold
      @warn_at = warn_at
      @max_bytes = max_bytes
      @batch_size = batch_size
      @timeout = timeout
      @cache_path = cache_path
    end

    def model_label
      "#{provider}/#{model}"
    end

    def api_key
      api_key_env.to_s.empty? ? nil : ENV.fetch(api_key_env, nil)
    end
  end

  # Decision-model services that speak System One.
  PROVIDERS = {
    "typesafe" => {
      "api_base" => "https://api.typesafe.ai", "api_key_env" => "TYPESAFE_API_KEY", "model" => "jev-latest"
    },
    "celeris" => {
      "api_base" => "https://inference.celeris.ai/celeris-1-decision",
      "api_key_env" => "CELERIS_API_KEY", "model" => "celeris-1-decision"
    },
    "openrouter" => {
      "api_base" => "https://openrouter.ai/api", "api_key_env" => "OPENROUTER_API_KEY", "model" => "jaredpalmer/kev-4b"
    }
  }.freeze

  module ConfigLoader
    FILE = ".judgelint.yml"
    KEYS = %w[
      provider model api_base api_key_env provider_options
      rules threshold warn_at max_bytes batch_size timeout cache
    ].freeze

    def self.load(path: nil, overrides: {})
      data = read(path || FILE, required: !path.nil?).merge(overrides)
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
      threshold = number(data, "threshold", 0.7)
      warn_at = number(data, "warn_at", 0.4)
      raise ConfigError, "warn_at must be below threshold" unless warn_at < threshold

      options = data.fetch("provider_options", {})
      raise ConfigError, "provider_options must be a mapping" unless options.is_a?(Hash)

      Config.new(
        provider: provider,
        model: setting(data, preset, "model"),
        api_base: setting(data, preset, "api_base"),
        api_key_env: setting(data, preset, "api_key_env"),
        provider_options: options,
        rules_dir: data.fetch("rules", ".judgelint/rules").to_s,
        threshold: threshold,
        warn_at: warn_at,
        max_bytes: number(data, "max_bytes", 60_000).to_i,
        batch_size: number(data, "batch_size", 32).to_i,
        timeout: number(data, "timeout", 30),
        cache_path: cache_path(data)
      )
    end

    def self.setting(data, preset, key)
      value = data.fetch(key, preset[key])
      raise ConfigError, "#{key} is required for provider #{data['provider']}" if value.nil? && key == "model"

      value&.to_s
    end

    def self.number(data, key, default)
      # Not fetch(key, default): Spinel miscompiles a Float default on a YAML hash.
      number = RuleLoader.number(data.key?(key) ? data[key] : default)
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
