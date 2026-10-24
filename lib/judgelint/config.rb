# frozen_string_literal: true

module Judgelint
  # .judgelint.yml: which models to ask, the threshold, files to ignore, and a
  # spending limit. Everything else has a fixed value.
  #
  #   models: [typesafe, cloudflare:clef]   # ask both and average
  #   threshold: 0.7
  #   ignore: ["vendor/**"]
  #   max_cost_usd: 1.00
  class Config
    FILE = ".judgelint.yml"
    KEYS = %w[models threshold ignore max_cost_usd].freeze
    RULES_DIR = ".judgelint/rules"
    CACHE = ".judgelint/cache.json"
    WINDOW_LINES = 40
    THREADS = 8
    # Answers this far below the threshold, or less, are uncertain: reported, never failing.
    UNCERTAIN_BAND = 0.3

    attr_reader :models, :threshold, :ignore, :max_cost_usd

    # +overrides+ replaces the file's settings: --model replaces its models.
    def self.load(path: nil, overrides: {})
      new(Judgelint.read_yaml(path || FILE, required: !path.nil?).merge(overrides))
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
      raise ConfigError, "#{FILE}: unknown keys #{unknown.join(', ')} (it takes #{KEYS.join(', ')})" unless unknown.empty?

      entries = data.fetch("models", "typesafe")
      entries = [entries] unless entries.is_a?(Array)
      raise ConfigError, "models needs at least one model" if entries.empty?

      @models = entries.map { |entry| Endpoint.from(entry) }
      @threshold = Judgelint.number(data.key?("threshold") ? data["threshold"] : 0.7)
      raise ConfigError, "threshold must be a number between 0 and 1" unless @threshold&.between?(0.01, 1)

      @ignore = list(data["ignore"])
      @max_cost_usd = Judgelint.number(data.key?("max_cost_usd") ? data["max_cost_usd"] : 1)
      raise ConfigError, "max_cost_usd must be a number" if @max_cost_usd.nil?
    end

    def warn_at
      [threshold - UNCERTAIN_BAND, 0.0].max
    end

    def label
      models.map(&:label).join(" + ")
    end

    private

    def list(value)
      return [] if value.nil?

      value.is_a?(Array) ? value.map(&:to_s) : [value.to_s]
    end
  end

  # One model to ask, and how to reach it: a provider preset and model id
  # ("typesafe", "cloudflare:clef", "openrouter:typesafe/jev-1.13"), or a
  # mapping for an endpoint judgelint has no preset for.
  class Endpoint
    KEYS = %w[
      provider model api_base path protocol auth api_key_env headers provider_options
      price_per_million batch_size max_state_tokens max_request_tokens
    ].freeze
    TIMEOUT = 30
    RETRIES = 3

    attr_reader :provider, :model, :api_base, :path, :protocol, :auth, :api_key_env, :headers,
                :provider_options, :price_per_million, :batch_size, :max_state_tokens, :max_request_tokens, :needs

    def self.from(entry)
      return new(entry) if entry.is_a?(Hash)

      provider, model = entry.to_s.split(":", 2)
      data = { "provider" => provider }
      data["model"] = model if model && !model.empty?
      new(data)
    end

    def initialize(data)
      unknown = data.keys - KEYS
      raise ConfigError, "models: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      @data = data
      @provider = data.fetch("provider", "custom").to_s
      @preset = PROVIDERS.fetch(@provider, {})
      @model = setting("model")
      @api_base = setting("api_base")
      @path = setting("path") || "/v1/systemone"
      @protocol = setting("protocol") || "system_one"
      @auth = setting("auth") || "bearer"
      @api_key_env = setting("api_key_env")
      @headers = mapping("headers")
      @provider_options = mapping("provider_options")
      @price_per_million = price
      @batch_size = count("batch_size", 32)
      # A request's state plus its widest question, and a whole request: Jev's
      # 32k and 64k token limits, with room for the estimate to be off.
      @max_state_tokens = count("max_state_tokens", 30_000)
      @max_request_tokens = count("max_request_tokens", 60_000)
      @needs = @preset["needs"]
    end

    def label
      "#{provider}:#{model}"
    end

    def api_key
      api_key_env.to_s.empty? ? nil : ENV.fetch(api_key_env, nil)
    end

    private

    def setting(key)
      value = @data.key?(key) ? @data[key] : @preset[key]
      value.nil? ? nil : value.to_s
    end

    def mapping(key)
      value = @data.fetch(key, {})
      raise ConfigError, "models: #{key} must be a mapping" unless value.is_a?(Hash)

      value
    end

    # A preset's prices are per model; another model has no price unless the
    # entry gives one, and its cost shows as unknown.
    def price
      return Judgelint.number(@data["price_per_million"]) if @data.key?("price_per_million")

      prices = @preset["prices"] || {}
      prices.key?(@model.to_s) ? Judgelint.number(prices[@model.to_s]) : nil
    end

    def count(key, default)
      # Not fetch(key, default): Spinel miscompiles a Float default on a YAML hash.
      value = @data.key?(key) ? @data[key] : @preset[key]
      number = Judgelint.number(value.nil? ? default : value)
      raise ConfigError, "models: #{key} must be a whole number of at least 1" if number.nil? || number < 1

      number.to_i
    end
  end
end
