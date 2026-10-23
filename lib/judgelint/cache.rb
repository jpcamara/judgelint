# frozen_string_literal: true

module Judgelint
  # Stores each answer under a hash of everything that produced it: the state
  # the model saw (path and numbered contents), the question asked of it, and
  # the model. Changing any of them is a miss. Safe to share across threads.
  class Cache
    def initialize(path)
      @path = path
      @entries = load_entries
      @dirty = false
      @lock = Mutex.new
    end

    def self.key(question_digest, state, model_label)
      Digest::SHA256.hexdigest([question_digest, Digest::SHA256.hexdigest(state), model_label].join(":"))
    end

    def fetch(key)
      @lock.synchronize { @entries[key] }
    end

    def store(key, yes_probability)
      @lock.synchronize do
        @entries[key] = yes_probability
        @dirty = true
      end
    end

    def save
      @lock.synchronize do
        return unless @path && @dirty

        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, "#{JSON.pretty_generate(@entries.sort.to_h)}\n")
        @dirty = false
      end
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
