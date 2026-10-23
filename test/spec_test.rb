# frozen_string_literal: true

require "test_helper"

class SpecTest < Minitest::Test
  include ProjectHelpers

  SERVICES = <<~MARKDOWN
    ---
    paths: ["src/services/*.ts"]
    excludes: ["src/services/legacy.ts"]
    ---
    # Service conventions

    Every file here is one service.

    - **Domain failures are values, never exceptions.** A service returns
      `{ ok: false, error }` for anything a caller could cause.
    - Services should prefer small inputs.
      - Nested detail stays with its bullet.

    ```ts
    - not a rule, it's in a code fence
    ```

    1. **No I/O except through the injected Store**: no timers, no fetch.
  MARKDOWN

  def test_each_top_level_bullet_is_a_rule
    in_project do
      write("src/services/README.md", SERVICES)
      rules = discover

      assert_equal %w[
        src/services/domain-failures-are-values-never-exceptions
        src/services/services-should-prefer-small-inputs
        src/services/no-i-o-except-through-the
      ], rules.map(&:id)

      values = rules.first
      assert_equal "Domain failures are values, never exceptions. A service returns `{ ok: false, error }` " \
                   "for anything a caller could cause.", values.convention
      assert_equal "Domain failures are values, never exceptions.", values.message
      assert_equal ["src/services/*.ts"], values.paths
      assert_equal ["src/services/legacy.ts"], values.excludes
      assert_equal ".judgelint/examples/src/services/domain-failures-are-values-never-exceptions", values.examples_dir
      assert_equal "Services should prefer small inputs. Nested detail stays with its bullet.", rules[1].convention
      assert_equal "No I/O except through the injected Store.", rules[2].message
    end
  end

  def test_severity_follows_the_wording_unless_the_spec_sets_it
    in_project do
      write("src/services/README.md", SERVICES)
      assert_equal %w[error warning error], discover.map(&:severity)

      write("src/services/README.md", SERVICES.sub("excludes:", "severity: warning\nexcludes:"))
      assert_equal %w[warning warning warning], discover.map(&:severity)
    end
  end

  def test_praxis_cohorts_and_scope
    in_project do
      write("src/features/README.md", "---\npaths: [\"src/features/*\"]\ncohort: by_directory\ncontext: [\"src/types.ts\"]\n---\n- One capability per feature.\n")
      write("tests/README.md", "---\npaths: [\"tests/*.ts\"]\ncohort: by_file\n---\n- One expect per it.\n")
      write("docs.judgelint.md", "---\npaths: [\"docs/**/*.md\"]\n---\n- Headings are sentence case.\n")
      rules = discover.to_h { |rule| [rule.id, rule] }

      assert_equal "directory", rules.fetch("src/features/one-capability-per-feature").scope
      assert_equal ["src/types.ts"], rules.fetch("src/features/one-capability-per-feature").context
      assert_equal "file", rules.fetch("tests/one-expect-per-it").scope
      assert_equal "window", rules.fetch("docs/headings-are-sentence-case").scope
    end
  end

  def test_readmes_without_paths_are_not_specs
    in_project do
      write("README.md", "# A project\n\n- a bullet that isn't a rule\n")
      write("lib/README.md", "---\ntitle: notes\n---\n- also not a rule\n")
      write("vendor/README.md", "---\npaths: [\"vendor/**\"]\n---\n- ignored by config\n")
      write(".judgelint/rules/smell.md", "---\nquestion: Does this code smell?\n---\n")

      write("vendor/deep/er/README.md", "---\npaths: [\"vendor/**\"]\n---\n- ignored too\n")
      assert_equal ["smell"], discover(ignore: ["vendor/**"]).map(&:id)
    end
  end

  def test_a_rules_file_without_a_question_is_a_spec_and_needs_bullets
    in_project do
      write(".judgelint/rules/ruby.md", "---\npaths: [\"**/*.rb\"]\n---\n- **No silent rescues.** Log or re-raise.\n")
      assert_equal ["ruby/no-silent-rescues"], discover.map(&:id)

      write(".judgelint/rules/ruby.md", "---\npaths: [\"**/*.rb\"]\n---\nJust prose.\n")
      error = assert_raises(Judgelint::ConfigError) { discover }
      assert_match(/needs a question, or bullets/, error.message)
    end
  end

  def test_repeated_bullets_get_distinct_ids
    in_project do
      write("README.md", "---\npaths: [\"**/*.rb\"]\n---\n- Keep it short.\n- Keep it short, really.\n")
      assert_equal %w[root/keep-it-short root/keep-it-short-really], discover.map(&:id)

      write("README.md", "---\npaths: [\"**/*.rb\"]\n---\n- Keep it short.\n- Keep it short!\n")
      assert_equal %w[root/keep-it-short root/keep-it-short-2], discover.map(&:id)
    end
  end

  def test_unknown_spec_keys_and_cohorts_are_errors
    in_project do
      write("README.md", "---\npaths: [\"x\"]\nquestions: oops\n---\n- A rule.\n")
      assert_raises(Judgelint::ConfigError) { discover }

      write("README.md", "---\npaths: [\"x\"]\ncohort: by_repo\n---\n- A rule.\n")
      assert_raises(Judgelint::ConfigError) { discover }
    end
  end

  def test_a_convention_is_asked_whether_the_code_breaks_it
    rule = Judgelint::Rule.new({ "convention" => "No fetch outside the Store." }, source: "README.md")
    window = Judgelint::Question.new(rule, 41, 80)

    assert_equal "Do lines 41-80 of the file (the rest is context) break this convention? Answer yes only when " \
                 "those lines clearly break it, not when it doesn't apply to them. Convention: No fetch outside the Store.",
                 window.instructions
    assert_equal "The code clearly breaks the convention.", window.yes_means
    assert_equal "The code follows the convention, or the convention doesn't apply to it.", window.no_means
  end

  def test_ignore_keeps_files_out_of_a_check
    in_project do
      write("src/services/README.md", SERVICES)
      write(".judgelint.yml", "ignore: [\"src/services/_*\"]\nmodels: [{api_base: \"http://127.0.0.1:1\", model: m, auth: none}]\n")
      write("src/services/_wip.ts", "throw new Error()\n")
      out = StringIO.new
      err = StringIO.new

      assert_equal 0, Judgelint::CLI.new([], out: out, err: err).run, err.string
      assert_equal "0 files, 0 violations\n", out.string
    end
  end

  private

  def discover(ignore: [])
    Judgelint::Spec.discover(rules_dir: ".judgelint/rules", default_threshold: 0.7, ignore: ignore)
  end
end
