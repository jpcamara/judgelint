# frozen_string_literal: true

require "test_helper"

class RuleLoaderTest < Minitest::Test
  include ProjectHelpers

  def test_reads_frontmatter_and_uses_the_body_for_the_message
    in_project do
      write(".judgelint/rules/no-silent-rescue.md", <<~MARKDOWN)
        ---
        question: Does this code swallow an exception?
        yes_means: A rescue drops the error.
        no_means: Errors are logged or re-raised.
        paths: "app/**/*.rb"
        excludes: ["app/legacy/**"]
        severity: warning
        threshold: 0.8
        ---
        # Heading

        Swallowed exceptions
        hide bugs.
      MARKDOWN

      rule = Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7).first

      assert_equal "no-silent-rescue", rule.id
      assert_equal "no_silent_rescue", rule.question_key
      assert_equal "A rescue drops the error.", rule.yes_means
      assert_equal ["app/**/*.rb"], rule.paths
      assert_equal "warning", rule.severity
      assert_in_delta 0.8, rule.threshold
      assert_equal "Swallowed exceptions hide bugs.", rule.message
      assert rule.applies_to?("app/services/foo.rb")
      assert rule.applies_to?("app/foo.rb")
      refute rule.applies_to?("app/legacy/old.rb")
      refute rule.applies_to?("lib/foo.rb")
    end
  end

  def test_bare_yes_and_no_from_yaml_still_mean_answers
    in_project do
      write_rule("validates", question: "Does this validate input first?", extra: "fail_when: no")
      rule = Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7).first

      assert_equal "no", rule.fail_when
      assert_in_delta 0.8, rule.violation_probability(0.2)
      assert_in_delta 0.7, rule.threshold
    end
  end

  def test_rejects_unknown_keys_and_missing_questions
    in_project do
      write(".judgelint/rules/bad.md", "---\nquestion: Q?\nyes: something\n---\n")
      error = assert_raises(Judgelint::ConfigError) do
        Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7)
      end
      assert_match(/unknown keys true/, error.message)

      write(".judgelint/rules/bad.md", "---\npaths: [x]\n---\n")
      error = assert_raises(Judgelint::ConfigError) do
        Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7)
      end
      assert_match(/needs a question/, error.message)
    end
  end

  def test_rejects_ids_that_collide_as_question_keys
    in_project do
      write_rule("a-b")
      write_rule("a_b")
      error = assert_raises(Judgelint::ConfigError) do
        Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7)
      end
      assert_match(/collide/, error.message)
    end
  end

  def test_rejects_bad_thresholds
    in_project do
      write_rule("smell", extra: "threshold: high")
      assert_raises(Judgelint::ConfigError) do
        Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7)
      end

      write_rule("smell", extra: "threshold: 1.5")
      assert_raises(Judgelint::ConfigError) do
        Judgelint::RuleLoader.load_dir(".judgelint/rules", default_threshold: 0.7)
      end
    end
  end
end
