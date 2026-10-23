# frozen_string_literal: true

module Judgelint
  # Stores each answer under a hash of everything that produced it: the state
  # the model saw (path and contents), what the rule asks, and the model.
  # Changing any of them is a miss.
  class Cache
    def initialize(path)
      @path = path
      @entries = load_entries
      @dirty = false
    end

    def self.key(rule, state, model_label)
      Digest::SHA256.hexdigest([rule.digest, Digest::SHA256.hexdigest(state), model_label].join(":"))
    end

    def fetch(key)
      @entries[key]
    end

    def store(key, yes_probability)
      @entries[key] = yes_probability
      @dirty = true
    end

    def save
      return unless @path && @dirty

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{JSON.pretty_generate(@entries.sort.to_h)}\n")
      @dirty = false
    end

    private

    def load_entries
      return {} unless @path && File.exist?(@path)

      data = JSON.parse(File.read(@path))
      raise ConfigError, "#{@path} isn't a judgelint cache; delete it to start over" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise ConfigError, "#{@path} isn't valid JSON; delete it to start over"
    end
  end
end
