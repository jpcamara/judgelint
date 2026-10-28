# frozen_string_literal: true

require "test_helper"

# How a check plans, asks, and judges, seen through the stub server and the
# JSON report.
class RunnerTest < Minitest::Test
  include ProjectHelpers

  def teardown
    @server&.stop
  end

  def test_one_request_per_file_with_a_question_per_rule_and_window
    @server = StubSystemOne.new
    in_project do
      write_rule("smell")
      write(".judgelint/rules/tidy.md", "---\nquestion: Is this untidy?\npaths: [\"app/a.rb\"]\n---\nTidy.\n")
      write("app/a.rb", "SMELL\n" * 50)
      write("app/b.rb", "fine\n")
      _status, out, = judgelint("-f", "json")

      requests = @server.requests.sort_by { |request| request[:payload]["state"] }
      assert_equal [%w[smell.1-40 smell.41-50 tidy.1-40 tidy.41-50], %w[smell.1-1]],
                   requests.map { |request| request[:payload]["questions"].keys }
      assert_equal "Path: app/b.rb\n\n1: fine\n", requests.last[:payload]["state"]
      assert_equal [["app/a.rb", "smell", "violation", [1, 40]], ["app/a.rb", "tidy", "violation", [1, 40]],
                    ["app/b.rb", "smell", "pass", [1, 1]]],
                   results(out).map { |result| result.values_at("path", "rule", "status", "lines") }
    end
  end

  def test_the_verdict_is_the_worst_window
    @server = StubSystemOne.new { |_state, key| key == "smell.41-80" ? 0.95 : 0.2 }
    in_project do
      write_rule("smell")
      write("app/a.rb", "x\n" * 100)
      _status, out, = judgelint("-f", "json")

      assert_equal ["violation", [41, 80], 0.95], results(out).first.values_at("status", "lines", "probability")
    end
  end

  def test_file_scope_asks_once_about_the_whole_file
    @server = StubSystemOne.new
    in_project do
      write_rule("smell", extra: "fail_when: no")
      write("app/a.rb", "x\n" * 100)
      _status, out, = judgelint("-f", "json")

      assert_equal [%w[smell.1-100]], @server.requests.map { |request| request[:payload]["questions"].keys }
      assert_equal ["violation", 0.9], results(out).first.values_at("status", "probability")
    end
  end

  def test_rules_with_different_context_get_their_own_requests
    @server = StubSystemOne.new
    in_project do
      write_rule("plain")
      write_rule("typed", extra: "context: [\"app/types.rb\"]")
      write("app/a.rb", "x\n")
      write("app/types.rb", "T\n")
      judgelint("app/a.rb")

      requests = @server.requests.sort_by { |request| request[:payload]["questions"].keys }
      assert_equal [%w[plain.1-1], %w[typed.1-1]], requests.map { |request| request[:payload]["questions"].keys }
      refute_includes requests.first[:payload]["state"], "app/types.rb"
      assert_includes requests.last[:payload]["state"], "Path: app/types.rb"
    end
  end

  def test_a_change_inside_a_directory_brings_the_directory_in
    @server = StubSystemOne.new
    in_project do
      write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                            "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
      write("app/features/a/index.rb", "x\n")
      write("app/features/b/index.rb", "x\n")
      git_repo
      write("app/features/b/index.rb", "y\n")
      judgelint("--base", "main")

      assert_equal 1, @server.requests.size
      assert_match(%r{\ADirectory: app/features/b\n}, @server.requests.first[:payload]["state"])
    end
  end

  def test_directory_examples_are_the_directories_under_pass_and_fail
    @server = StubSystemOne.new
    in_project do
      write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                            "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
      write(".judgelint/rules/cohesive/fail/orphan/index.rb", "x\n")
      write(".judgelint/rules/cohesive/fail/orphan/unused.rb", "SMELL\n")
      write(".judgelint/rules/cohesive/pass/tidy/index.rb", "x\n")
      status, out, = judgelint("test", "-f", "json")

      assert_equal 0, status
      assert_equal [true, true], JSON.parse(out)["examples"].map { |example| example["correct"] }
      assert_equal(["Directory: orphan", "Directory: tidy"],
                   @server.requests.map { |request| request[:payload]["state"].lines.first.chomp }.sort)
    end
  end

  def test_refusals_are_reported_not_passed_or_cached
    @server = StubSystemOne.new { nil }
    in_project do
      write_rule("smell")
      write("app/a.rb", "x")
      status, out, = judgelint("-f", "json", cache: true)
      assert_equal [0, "refused"], [status, results(out).first["status"]]

      judgelint("-f", "json", cache: true)
      assert_equal 2, @server.requests.size
    end
  end

  def test_a_directory_finding_names_its_file
    @server = StubSystemOne.new do |_state, key|
      key.end_with?(".where") ? { "app/feature/index.rb" => 0.1, "app/feature/stray.rb" => 0.9 } : 0.9
    end
    in_project do
      write("app/README.md", "---\npaths: [\"app/*\"]\nscope: directory\n---\n- Every file is used.\n")
      write("app/feature/index.rb", "x\n")
      write("app/feature/stray.rb", "y\n")
      _status, out, = judgelint("-f", "json")

      where = @server.requests.first[:payload]["questions"].find { |key, _| key.end_with?(".where") }.last
      assert_equal %w[app/feature/index.rb app/feature/stray.rb], where["criteria"].keys
      assert_equal ["app/feature/stray.rb", nil], results(out).first.values_at("file", "line")
    end
  end

  def test_every_model_is_asked_and_their_answers_averaged
    @server = StubSystemOne.new
    clef = StubSystemOne.new { |_state, key| key == "smell.1-40" ? 0.5 : nil }
    in_project do
      write_rule("smell")
      write("app/a.rb", "SMELL\n" * 50)
      _status, out, = judgelint("-f", "json", config: { "models" => [jev, other("clef", clef)] })

      [@server, clef].each do |server|
        assert_equal [%w[smell.1-40 smell.41-50]], server.requests.map { |request| request[:payload]["questions"].keys }
      end
      assert_equal [0.9, [41, 50]], results(out).first.values_at("probability", "lines"),
                   "41-50: clef refused, so it's jev's 0.9 alone"
    end
  ensure
    clef&.stop
  end

  def test_each_models_answers_are_cached_on_their_own
    @server = StubSystemOne.new { 0.2 }
    clef = StubSystemOne.new { 0.8 }
    in_project do
      write_rule("smell")
      write("app/a.rb", "x")
      judgelint(cache: true)
      _status, out, = judgelint("-f", "json", config: { "models" => [jev, other("clef", clef)] }, cache: true)

      assert_equal 1, @server.requests.size, "jev's answer came from the cache"
      assert_equal 1, clef.requests.size
      assert_equal 0.5, results(out).first["probability"]
    end
  ensure
    clef&.stop
  end

  def test_a_files_requests_go_out_at_once
    @server = StubSystemOne.new(together: 5)
    in_project do
      write_rule("a")
      write_rule("b")
      write("app/a.rb", "x\n" * 200)
      status, = judgelint(model: { "batch_size" => 2 })

      assert_equal [0, 5], [status, @server.requests.size]
      refute @server.apart, "all five requests were in flight before any was answered"
    end
  end

  def test_a_judgehint_is_asked_about_for_its_window_only
    @server = StubSystemOne.new { |_state, key| key.include?("41-60") ? 0.1 : 0.9 }
    in_project do
      write_rule("smell")
      write("app/a.rb", ["# judgehint: the rescue re-raises after logging", *(["x"] * 59)].join("\n"))
      status, out, = judgelint("-f", "json")

      assert_equal [%w[smell.1-40 smell.1-40.excused smell.41-60]],
                   @server.requests.map { |request| request[:payload]["questions"].keys }
      assert_equal [0, "excused", [1, 40], 0.9], [status, *results(out).first.values_at("status", "lines", "probability")]
    end
  end

  def test_a_judgehint_that_does_not_excuse_the_code_leaves_the_violation
    @server = StubSystemOne.new { |_state, key| key.end_with?(".excused") ? 0.2 : 0.9 }
    in_project do
      write_rule("smell")
      write("app/a.rb", "# judgehint: written quickly\nx\n")
      _status, out, = judgelint("-f", "json")

      assert_equal ["violation"], results(out).map { |result| result["status"] }
    end
  end

  def test_a_violation_elsewhere_outranks_an_excused_window
    @server = StubSystemOne.new { 0.9 }
    in_project do
      write_rule("smell")
      write("app/a.rb", ["# judgehint: intentional", *(["x"] * 59)].join("\n"))
      _status, out, = judgelint("-f", "json")

      assert_equal ["violation", [41, 60]], results(out).first.values_at("status", "lines")
    end
  end

  def test_cache_answers_repeat_runs_until_the_file_or_rule_changes
    @server = StubSystemOne.new
    in_project do
      write_rule("smell")
      write("app/a.rb", "x")
      2.times { judgelint(cache: true) }
      assert_equal 1, @server.requests.size

      write("app/a.rb", "y")
      judgelint(cache: true)
      assert_equal 2, @server.requests.size

      write_rule("smell", question: "Reworded?")
      judgelint(cache: true)
      assert_equal 3, @server.requests.size

      write_rule("smell", extra: "severity: warning\nthreshold: 0.9")
      judgelint(cache: true)
      assert_equal 3, @server.requests.size, "severity and threshold aren't shown to the model"
    end
  end

  def test_a_corrupt_cache_is_an_error_not_an_empty_cache
    @server = StubSystemOne.new
    in_smelly_project do
      write(".judgelint/cache.bin", "{not json")
      status, _out, err = judgelint("app/bad.rb", cache: true)

      assert_equal 2, status
      assert_match(/delete it/, err)
      assert_equal "{not json", File.read(".judgelint/cache.bin")
      assert_empty @server.requests
    end
  end

  def test_results_keep_file_order_across_threads
    @server = StubSystemOne.new do |state, _key|
      sleep(rand / 100)
      state.include?("SMELL") ? 0.9 : 0.1
    end
    in_project do
      write_rule("smell")
      paths = (1..12).map { |index| format("app/f%02d.rb", index) }
      paths.each_with_index { |path, index| write(path, index.even? ? "SMELL" : "fine") }
      _status, out, = judgelint("-f", "json")

      assert_equal paths, results(out).map { |result| result["path"] }
      assert_equal(paths.each_index.map { |index| index.even? ? "violation" : "pass" },
                   results(out).map { |result| result["status"] })
    end
  end

  def test_fixtures_hide_their_pass_and_fail_directories
    @server = StubSystemOne.new
    in_project do
      write_rule("smell")
      write(".judgelint/rules/smell/fail/bad.rb", "SMELL")
      write(".judgelint/rules/smell/pass/good.rb", "fine")
      write(".judgelint/rules/smell/pass/nested/also_bad.rb", "SMELL")
      _status, out, = judgelint("test", "-f", "json")

      correct = JSON.parse(out)["examples"].to_h { |example| [example["path"], example["correct"]] }
      assert_equal({ ".judgelint/rules/smell/fail/bad.rb" => true, ".judgelint/rules/smell/pass/good.rb" => true,
                     ".judgelint/rules/smell/pass/nested/also_bad.rb" => false }, correct)
      assert_equal(%w[bad.rb good.rb nested/also_bad.rb],
                   @server.requests.map { |request| request[:payload]["state"][/Path: (\S+)/, 1] }.sort)
    end
  end

  def test_bad_and_good_blocks_are_shown_as_example_files
    @server = StubSystemOne.new
    in_project do
      write("CONVENTIONS.md", "- **No smells.**\n\n  Bad:\n\n  ```ruby\n  SMELL\n  ```\n\n  Good:\n\n  ```ruby\n  fine\n  ```\n")
      judgelint("test")
      assert_equal(%w[example.ruby example.ruby],
                   @server.requests.map { |request| request[:payload]["state"]["file"][/Path: (\S+)/, 1] })

      write("CONVENTIONS.md", File.read("CONVENTIONS.md").sub("Good:", "Bad:"))
      status, _out, err = judgelint("test")
      assert_equal 2, status
      assert_match(%r{add a Good block under root/no-smells}, err)
    end
  end

  private

  def results(out)
    JSON.parse(out)["results"]
  end

  def jev
    { "provider" => "typesafe", "api_base" => @server.base, "api_key_env" => "JUDGELINT_TEST_KEY" }
  end

  def other(model, server)
    { "provider" => "custom", "model" => model, "api_base" => server.base, "auth" => "none" }
  end
end
