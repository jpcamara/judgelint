# frozen_string_literal: true

require "test_helper"

class RunnerTest < Minitest::Test
  include ProjectHelpers

  def test_one_request_per_file_with_a_question_per_rule_and_window
    in_project do
      write("app/a.rb", "SMELL\n" * 50)
      write("app/b.rb", "fine\n")
      rules = [rule("smell"), rule("other", paths: ["app/a.rb"])]
      client = FakeClient.new { |state, _question| state.include?("SMELL") ? 0.9 : 0.1 }

      verdicts = judge(rules, client, %w[app/a.rb app/b.rb])

      assert_equal [%w[smell.1-40 smell.41-50 other.1-40 other.41-50], %w[smell.1-1]], client.calls.map(&:last)
      assert_equal "Path: app/b.rb\n\n1: fine\n", client.calls.last.first
      assert_equal %i[violation violation pass], verdicts.map(&:status)
      assert_equal [[1, 40], [1, 40], [1, 1]], verdicts.map(&:lines)
    end
  end

  def test_the_verdict_is_the_worst_window
    in_project do
      write("app/a.rb", "x\n" * 100)
      client = FakeClient.new { |_state, question| question.first == 41 ? 0.95 : 0.2 }
      verdict = judge([rule], client, ["app/a.rb"]).first

      assert_equal :violation, verdict.status
      assert_equal [41, 80], verdict.lines
      assert_in_delta 0.95, verdict.probability
    end
  end

  def test_file_scope_asks_once_about_the_whole_file
    in_project do
      write("app/a.rb", "x\n" * 100)
      client = FakeClient.new { 0.1 }
      verdict = judge([rule(fail_when: "no")], client, ["app/a.rb"]).first

      assert_equal [%w[smell.1-100]], client.calls.map(&:last)
      assert_equal :violation, verdict.status
      assert_in_delta 0.9, verdict.probability
    end
  end

  def test_only_windows_a_change_touched
    in_project do
      write("app/a.rb", "x\n" * 130)
      write("app/b.rb", "x\n" * 10)
      client = FakeClient.new { 0.1 }
      judge([rule], client, %w[app/a.rb app/b.rb], changes: { "app/a.rb" => [45, 125], "app/b.rb" => :all })

      assert_equal [%w[smell.41-80 smell.121-130], %w[smell.1-10]], client.calls.map(&:last)
    end
  end

  def test_thresholds_and_the_uncertain_band
    in_project do
      write("app/a.rb", "x")
      { 0.75 => :violation, 0.5 => :uncertain, 0.39 => :pass }.each do |probability, status|
        verdict = judge([rule], FakeClient.new { probability }, ["app/a.rb"]).first
        assert_equal status, verdict.status, "probability #{probability}"
      end
    end
  end

  def test_warnings_never_fail_the_run
    in_project do
      write("app/a.rb", "x")
      verdict = judge([rule(severity: "warning")], FakeClient.new { 0.9 }, ["app/a.rb"]).first

      assert_equal :violation, verdict.status
      refute verdict.failing?
    end
  end

  def test_refusals_are_reported_not_passed_or_cached
    in_project do
      write("app/a.rb", "x")
      client = FakeClient.new { nil }
      cached = config(cache: ".judgelint/cache.json")

      verdict = judge([rule], client, ["app/a.rb"], config: cached).first
      assert_equal :refused, verdict.status
      refute verdict.failing?

      judge([rule], client, ["app/a.rb"], config: cached)
      assert_equal 2, client.calls.size
    end
  end

  def test_a_file_over_the_token_budget_is_skipped_before_anything_is_sent
    in_project do
      write("app/a.rb", "x" * 400)
      client = FakeClient.new { 0.9 }
      runner = runner([rule], client, config(max_state_tokens: 100))
      jobs = runner.plan(["app/a.rb"])

      assert_equal 0, runner.request_count(jobs)
      assert_equal :skipped, runner.execute(jobs).flatten.first.status
      assert_empty client.calls
    end
  end

  def test_packs_questions_by_tokens_and_count
    in_project do
      write("app/a.rb", "x\n" * 200)
      client = FakeClient.new { 0.1 }
      runner = runner([rule("a"), rule("b")], client, config(batch_size: 4))
      jobs = runner.plan(["app/a.rb"])

      assert_equal [4, 4, 2], jobs.first.requests.map { |request| request.questions.size }
      assert_equal 3, runner.request_count(jobs)
      assert_equal jobs.first.requests.sum(&:tokens), runner.estimated_tokens(jobs)

      small = runner([rule("a"), rule("b")], client, config(max_request_tokens: 120)).plan(["app/a.rb"])
      assert_operator small.first.requests.size, :>, 3
    end
  end

  def test_repeat_averages_samples
    in_project do
      write("app/a.rb", "x")
      samples = [0.6, 0.9, 0.9]
      client = FakeClient.new { samples.shift }
      verdict = judge([rule], client, ["app/a.rb"], config: config(repeat: 3)).first

      assert_equal 3, client.calls.size
      assert_in_delta 0.8, verdict.probability
    end
  end

  def test_suppressions_cover_their_window_or_the_whole_file
    in_project do
      write("app/a.rb", ["# judgelint:disable smell -- reviewed: the rescue re-raises", *(["x"] * 59)].join("\n"))
      write("app/b.rb", "# judgelint:disable-file smell, other -- generated\nx\n")
      client = FakeClient.new { 0.9 }
      verdicts = judge([rule("smell"), rule("other")], client, %w[app/a.rb app/b.rb])

      assert_equal [%w[smell.41-60 other.1-40 other.41-60]], client.calls.map(&:last)
      assert_equal %i[violation violation suppressed suppressed], verdicts.map(&:status)
    end
  end

  def test_suppressions_are_only_read_from_comments
    in_project do
      write("app/a.rb", %(raise "\#{path}: judgelint:disable needs a reason"\n// judgelint:disable smell -- js style\n))
      client = FakeClient.new { 0.9 }
      verdicts = judge([rule], client, ["app/a.rb"])

      assert_empty client.calls
      assert_equal [:suppressed], verdicts.map(&:status)
    end
  end

  def test_suppressions_need_a_reason_and_a_known_rule
    in_project do
      write("app/a.rb", "x # judgelint:disable smell\n")
      error = assert_raises(Judgelint::ConfigError) { runner([rule], FakeClient.new { 0.1 }).plan(["app/a.rb"]) }
      assert_match(%r{app/a.rb:1: judgelint:disable needs rule ids and a reason}, error.message)

      write("app/a.rb", "x # judgelint:disable smel -- typo\n")
      error = assert_raises(Judgelint::ConfigError) { runner([rule], FakeClient.new { 0.1 }).plan(["app/a.rb"]) }
      assert_match(/unknown rules smel/, error.message)
    end
  end

  def test_cache_answers_repeat_runs_until_the_file_or_rule_changes
    in_project do
      write("app/a.rb", "x")
      client = FakeClient.new { 0.9 }
      cached = config(cache: ".judgelint/cache.json")

      2.times { judge([rule], client, ["app/a.rb"], config: cached) }
      assert_equal 1, client.calls.size

      write("app/a.rb", "y")
      judge([rule], client, ["app/a.rb"], config: cached)
      assert_equal 2, client.calls.size

      judge([rule(question: "Reworded?")], client, ["app/a.rb"], config: cached)
      assert_equal 3, client.calls.size

      judge([rule(severity: "warning", threshold: 0.9)], client, ["app/a.rb"], config: cached)
      assert_equal 3, client.calls.size, "severity and threshold aren't shown to the model"
    end
  end

  def test_a_corrupt_cache_is_an_error_not_an_empty_cache
    in_project do
      write(".judgelint/cache.json", "{not json")
      error = assert_raises(Judgelint::ConfigError) { Judgelint::Cache.new(".judgelint/cache.json") }
      assert_match(/delete it/, error.message)
    end
  end

  def test_results_keep_file_order_across_threads
    in_project do
      paths = (1..12).map { |index| "app/f#{index}.rb" }
      paths.each_with_index { |path, index| write(path, index.even? ? "SMELL" : "fine") }
      client = FakeClient.new do |state, _question|
        sleep(rand / 100)
        state.include?("SMELL") ? 0.9 : 0.1
      end
      verdicts = judge([rule], client, paths, config: config(threads: 6))

      assert_equal paths, verdicts.map(&:path)
      assert_equal(paths.each_index.map { |index| index.even? ? :violation : :pass }, verdicts.map(&:status))
    end
  end

  def test_fixtures_hide_their_pass_and_fail_directories
    in_project do
      write(".judgelint/rules/smell/fail/bad.rb", "SMELL")
      write(".judgelint/rules/smell/pass/good.rb", "fine")
      write(".judgelint/rules/smell/pass/nested/also_bad.rb", "SMELL")
      client = FakeClient.new { |state, _question| state.include?("SMELL") ? 0.9 : 0.1 }
      runner = runner([rule], client)
      examples = runner.execute(runner.plan_examples).flatten

      assert_equal [true, false, true], examples.map(&:correct?)
      assert_equal(%w[good.rb nested/also_bad.rb bad.rb], client.calls.map { |state, _keys| state[/Path: (\S+)/, 1] })
    end
  end

  def test_every_rule_needs_pass_and_fail_examples_before_anything_is_sent
    in_project do
      write(".judgelint/rules/smell/fail/bad.rb", "SMELL")
      client = FakeClient.new { 0.9 }
      error = assert_raises(Judgelint::ConfigError) { runner([rule], client).plan_examples }

      assert_match(%r{\.judgelint/rules/smell/pass/}, error.message)
      assert_empty client.calls
    end
  end

  private

  def runner(rules, client, config = self.config)
    Judgelint::Runner.new(config: config, rules: rules, client: client, cache: Judgelint::Cache.new(config.cache_path))
  end

  def judge(rules, client, paths, config: self.config, changes: nil)
    runner = runner(rules, client, config)
    runner.execute(runner.plan(paths, changes: changes)).flatten
  end
end
