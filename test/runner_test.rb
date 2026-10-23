# frozen_string_literal: true

require "test_helper"

class RunnerTest < Minitest::Test
  include ProjectHelpers

  def test_one_request_per_file_with_every_applicable_rule
    in_project do
      write("app/a.rb", "SMELL")
      write("app/b.rb", "fine")
      rules = [rule("smell"), rule("other", paths: ["app/a.rb"])]
      backend = FakeBackend.new { |state, _rule| state.include?("SMELL") ? 0.9 : 0.1 }

      verdicts = runner(rules, backend).run(["app/a.rb", "app/b.rb"])

      assert_equal [["Path: app/a.rb\n\nSMELL", %w[smell other]], ["Path: app/b.rb\n\nfine", %w[smell]]],
                   backend.calls
      assert_equal %i[violation violation pass], verdicts.map(&:status)
      assert(verdicts.first.failing?)
    end
  end

  def test_thresholds_and_the_uncertain_band
    in_project do
      write("app/a.rb", "x")
      cases = { 0.75 => :violation, 0.5 => :uncertain, 0.39 => :pass }
      cases.each do |probability, status|
        verdict = runner([rule], FakeBackend.new { probability }).run(["app/a.rb"]).first
        assert_equal status, verdict.status, "probability #{probability}"
      end
    end
  end

  def test_fail_when_no_inverts_the_answer
    in_project do
      write("app/a.rb", "x")
      verdict = runner([rule(fail_when: "no")], FakeBackend.new { 0.1 }).run(["app/a.rb"]).first

      assert_equal :violation, verdict.status
      assert_in_delta 0.9, verdict.probability
    end
  end

  def test_warnings_never_fail_the_run
    in_project do
      write("app/a.rb", "x")
      verdict = runner([rule(severity: "warning")], FakeBackend.new { 0.9 }).run(["app/a.rb"]).first

      assert_equal :violation, verdict.status
      refute verdict.failing?
    end
  end

  def test_large_files_are_skipped_not_passed
    in_project do
      write("app/a.rb", "x" * 100)
      backend = FakeBackend.new { 0.9 }
      verdict = runner([rule], backend, config(max_bytes: 10)).run(["app/a.rb"]).first

      assert_equal :skipped, verdict.status
      assert_empty backend.calls
    end
  end

  def test_cache_answers_repeat_runs_until_the_file_or_rule_changes
    in_project do
      write("app/a.rb", "x")
      backend = FakeBackend.new { 0.9 }
      cached = config(cache: ".judgelint/cache.json")

      2.times { runner([rule], backend, cached).run(["app/a.rb"]) }
      assert_equal 1, backend.calls.size

      write("app/a.rb", "y")
      runner([rule], backend, cached).run(["app/a.rb"])
      assert_equal 2, backend.calls.size

      runner([rule(question: "Reworded?")], backend, cached).run(["app/a.rb"])
      assert_equal 3, backend.calls.size

      runner([rule(severity: "warning", threshold: 0.9)], backend, cached).run(["app/a.rb"])
      assert_equal 3, backend.calls.size, "severity and threshold aren't shown to the model"
    end
  end

  def test_a_corrupt_cache_is_an_error_not_an_empty_cache
    in_project do
      write(".judgelint/cache.json", "{not json")
      error = assert_raises(Judgelint::ConfigError) { Judgelint::Cache.new(".judgelint/cache.json") }
      assert_match(/delete it/, error.message)
    end
  end

  def test_batches_questions
    in_project do
      write("app/a.rb", "x")
      rules = %w[a b c].map { |id| rule(id) }
      backend = FakeBackend.new { 0.1 }
      runner(rules, backend, config(batch_size: 2)).run(["app/a.rb"])

      assert_equal [%w[a b], %w[c]], backend.calls.map(&:last)
    end
  end

  def test_fixtures_hide_their_pass_and_fail_directories
    in_project do
      write(".judgelint/rules/smell/fail/bad.rb", "SMELL")
      write(".judgelint/rules/smell/pass/good.rb", "fine")
      write(".judgelint/rules/smell/pass/nested/also_bad.rb", "SMELL")
      backend = FakeBackend.new { |state, _rule| state.include?("SMELL") ? 0.9 : 0.1 }

      examples = Judgelint::FixtureRunner.new(runner([rule], backend)).run([rule])

      assert_equal [true, false, true], examples.map(&:correct?)
      assert_equal ["Path: good.rb\n\nfine", "Path: nested/also_bad.rb\n\nSMELL", "Path: bad.rb\n\nSMELL"],
                   backend.calls.map(&:first)
    end
  end

  private

  def runner(rules, backend, config = self.config)
    Judgelint::Runner.new(config: config, rules: rules, backend: backend, cache: Judgelint::Cache.new(config.cache_path))
  end
end
