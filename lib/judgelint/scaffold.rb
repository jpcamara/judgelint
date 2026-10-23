# frozen_string_literal: true

module Judgelint
  # Files written by `judgelint init`.
  module Scaffold
    CONFIG = <<~YAML
      # judgelint settings. See https://github.com/jpcamara/judgelint#configuration
      provider: typesafe      # typesafe (Jev), celeris, or openrouter (Kev)
      model: jev-latest
      # threshold: 0.7        # violation probability that counts as a violation
      # warn_at: 0.4          # below threshold but at least this is reported as uncertain
      rules: .judgelint/rules
    YAML

    RULE = <<~MARKDOWN
      ---
      question: Does this code rescue an exception and then carry on as if nothing happened?
      yes_means: A rescue neither logs the error, re-raises it, nor returns an explicit failure to the caller.
      no_means: Every rescue logs, re-raises, or turns the error into a result the caller sees. Code with no rescue counts as no.
      paths: ["**/*.rb"]
      excludes: ["test/**", "spec/**"]
      ---
      Swallowed exceptions hide bugs until they cost us data.

      RuboCop's Lint/SuppressedException only catches an empty rescue. This rule
      also catches a rescue that returns nil, or assigns a default, and moves on.
    MARKDOWN

    PASS_EXAMPLE = <<~RUBY
      def fetch_profile(id)
        client.profile(id)
      rescue Client::Timeout => e
        logger.warn("profile \#{id} timed out: \#{e.message}")
        raise
      end
    RUBY

    FAIL_EXAMPLE = <<~RUBY
      def fetch_profile(id)
        client.profile(id)
      rescue StandardError
        nil
      end
    RUBY

    def self.write(root, out)
      rule = ".judgelint/rules/no-silent-rescue"
      files = {
        ConfigLoader::FILE => CONFIG,
        "#{rule}.md" => RULE,
        File.join(rule, "pass", "logs_and_reraises.rb") => PASS_EXAMPLE,
        File.join(rule, "fail", "returns_nil.rb") => FAIL_EXAMPLE
      }
      files.each do |name, content|
        path = root == "." ? name : File.join(root, name)
        if File.exist?(path)
          out.puts "exists  #{path}"
        else
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          out.puts "create  #{path}"
        end
      end
    end
  end
end
