# frozen_string_literal: true

module Judgelint
  # Files written by `judgelint init`.
  module Scaffold
    # A spec: each bullet is a convention judgelint checks. A README with
    # paths: frontmatter works the same way, next to the code it governs.
    SPEC = <<~MARKDOWN
      ---
      paths: ["**/*.rb"]
      excludes: ["test/**", "spec/**"]
      ---
      # Ruby conventions

      - **No silent rescues.** A rescue logs the error, re-raises it, or turns it
        into a result the caller sees. Swallowed exceptions hide bugs until they
        cost us data.
      - **Error messages say what to do next.** A raised or returned error names
        what was wrong and what would work instead.
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
      examples = ".judgelint/examples/ruby/no-silent-rescues"
      files = {
        ".judgelint/rules/ruby.md" => SPEC,
        File.join(examples, "pass", "logs_and_reraises.rb") => PASS_EXAMPLE,
        File.join(examples, "fail", "returns_nil.rb") => FAIL_EXAMPLE
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
