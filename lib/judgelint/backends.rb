# frozen_string_literal: true

module Judgelint
  module Backends
    def self.build(config)
      if !config.api_key_env.to_s.empty? && config.api_key.to_s.empty?
        raise ConfigError, "Set #{config.api_key_env} to your #{config.provider} API key"
      end

      case config.resolved_backend
      when "system_one" then SystemOne.new(config)
      when "ruby_llm"
        if RUBY_ENGINE == "spinel"
          raise ConfigError, "The native binary has no RubyLLM; use backend: system_one or the judgelint gem"
        else
          RubyLLM.new(config)
        end
      end
    end
  end
end
