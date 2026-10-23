# frozen_string_literal: true

module Judgelint
  module Backends
    # Asks the rules through RubyLLM.judge (RubyLLM 2.1+). CRuby only.
    #
    # +provider+ is a RubyLLM provider name (typesafe, openai, ...). The System
    # One services judgelint knows (celeris, openrouter) go through RubyLLM's
    # TypeSafe provider pointed at that service. Extra providers, such as
    # ruby_llm-llm_judge's chat-model judge, load through `require:`.
    class RubyLLM
      def initialize(config)
        config.requires.each { |name| require name }
        require "ruby_llm"

        @config = config
        @provider = PROVIDERS.key?(config.provider) ? "typesafe" : config.provider
        @context = ::RubyLLM.context { |settings| configure(settings) }
      end

      def judge(state, rules)
        result = @context.judge(
          state,
          questions: self.class.questions(rules),
          model: @config.model,
          provider: @provider.to_sym,
          assume_model_exists: true,
          provider_options: @config.provider_options
        )
        rules.to_h { |rule| [rule.question_key, result.fetch(rule.question_key).probability.to_f] }
      rescue StandardError => e
        raise BackendError, "#{@config.model_label}: #{e.message.lines.first&.strip}"
      end

      def self.questions(rules)
        rules.to_h do |rule|
          criteria = { yes: rule.yes_means, no: rule.no_means }.compact
          question = { type: :probability, instructions: rule.question }
          question[:criteria] = criteria unless criteria.empty?
          [rule.question_key, question]
        end
      end

      private

      def configure(settings)
        key = @config.api_key
        set(settings, "#{@provider}_api_key", key) if key
        # RubyLLM resolves "v1/systemone" against the base, so it needs the trailing slash.
        base = @config.api_base
        base = "#{base.delete_suffix('/')}/" if base && @provider == "typesafe"
        set(settings, "#{@provider}_api_base", base) if base
      end

      def set(settings, name, value)
        return unless settings.respond_to?("#{name}=")

        settings.public_send("#{name}=", value)
      end
    end
  end
end
