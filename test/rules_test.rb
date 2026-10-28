# frozen_string_literal: true

require "test_helper"

# Which rules a project has, and which files they leave out.
class RulesTest < Minitest::Test
  include ProjectHelpers

  def setup
    @server = StubSystemOne.new
  end

  def teardown
    @server.stop
  end

  def test_rule_ids_that_collide_as_question_keys_are_an_error
    in_project do
      write_rule("a-b")
      write_rule("a_b")
      status, _out, err = judgelint("rules")

      assert_equal 2, status
      assert_match(/collide/, err)
    end
  end

  def test_readmes_without_paths_are_not_specs
    in_project do
      write("README.md", "# A project\n\n- a bullet that isn't a rule\n")
      write("lib/README.md", "---\ntitle: notes\n---\n- also not a rule\n")
      write("vendor/README.md", "---\npaths: [\"vendor/**\"]\n---\n- ignored by config\n")
      write("vendor/deep/er/README.md", "---\npaths: [\"vendor/**\"]\n---\n- ignored too\n")
      write(".judgelint/rules/smell.md", "---\nquestion: Does this code smell?\n---\n")
      status, out, = judgelint("rules", config: { "ignore" => ["vendor/**"] })

      assert_equal 0, status
      assert_equal ["smell"], out.lines.map { |line| line.split.first }
    end
  end

  def test_ignore_keeps_files_out_of_a_check
    in_project do
      write("src/services/README.md", "---\npaths: [\"src/services/*.ts\"]\n---\n- **Services return values.**\n")
      write("src/services/_wip.ts", "throw new Error()\n")
      status, out, = judgelint(config: { "ignore" => ["src/services/_*"] })

      assert_equal [0, "0 files, 0 violations\n"], [status, out]
      assert_empty @server.requests
    end
  end
end
