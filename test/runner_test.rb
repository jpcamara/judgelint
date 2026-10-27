# frozen_string_literal: true

require "test_helper"
require "timeout"

class RunnerTest < Minitest::Test
  include ProjectHelpers

  def test_one_request_per_file_with_a_question_per_rule_and_window
    in_project do
      write("app/a.rb", "SMELL\n" * 50)
      write("app/b.rb", "fine\n")
      rules = [rule("smell"), rule("other", paths: ["app/a.rb"])]
      client = FakeClient.new { |state, _question| state.include?("SMELL") ? 0.9 : 0.1 }

      verdicts = judge(rules, client, %w[app/a.rb app/b.rb])

      calls = client.calls.sort_by(&:first)
      assert_equal [%w[smell.1-40 smell.41-50 other.1-40 other.41-50], %w[smell.1-1]], calls.map(&:last)
      assert_equal "Path: app/b.rb\n\n1: fine\n", calls.last.first
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

  def test_a_window_rule_asks_about_the_changed_lines_alone
    in_project do
      write("app/a.rb", "x\n" * 130)
      asked = []
      client = FakeClient.new { |_state, question| asked << question.instructions[/\ALook at [^;]+/]; 0.1 }
      judge([rule, rule("whole", scope: "file")], client, %w[app/a.rb], changes: { "app/a.rb" => [45, 46, 125] })

      assert_equal ["Look at lines 45-46 of the file", "Look at line 125 of the file", nil], asked
    end
  end

  def test_a_finding_on_a_line_the_change_didnt_touch_passes
    in_project do
      write("app/a.rb", "x\n" * 50)
      bullet = Judgelint::Rule.new({ "convention" => "No smells.", "paths" => ["app/**/*.rb"] }, source: "README.md")
      # The where answer puts the finding on the window's first line, L41.
      client = FakeClient.new { 0.9 }
      untouched = judge([bullet], client, %w[app/a.rb], changes: { "app/a.rb" => [45] }).first
      touched = judge([bullet], client, %w[app/a.rb], changes: { "app/a.rb" => [41] }).first

      assert_equal [:pass, 0.0], [untouched.status, untouched.probability]
      assert_equal [:violation, 41], [touched.status, touched.line]
    end
  end

  def test_a_directory_rule_judges_each_directory_as_one_unit
    in_project do
      write("app/features/a/index.rb", "one\n")
      write("app/features/a/helper.rb", "SMELL\n")
      write("app/features/b/index.rb", "fine\n")
      write("app/types.rb", "Types = 1\n")
      rule = rule("cohesive", scope: "directory", paths: ["app/features/*"], context: ["app/types.rb"])
      client = FakeClient.new { |state, _question| state.include?("SMELL") ? 0.9 : 0.1 }
      verdicts = judge([rule], client, [], directories: %w[app/features/a app/features/b])

      assert_equal %w[app/features/a app/features/b], verdicts.map(&:path)
      assert_equal %i[violation pass], verdicts.map(&:status)
      assert_nil verdicts.first.lines
      assert_equal <<~STATE, client.calls.map(&:first).find { |state| state.start_with?("Directory: app/features/a") }
        Directory: app/features/a

        Path: app/features/a/helper.rb

        1: SMELL

        Path: app/features/a/index.rb

        1: one

        Context, for reference only (not under review):

        Path: app/types.rb

        Types = 1
      STATE
    end
  end

  def test_a_file_that_changes_after_planning_is_not_sent
    in_project do
      write("app/a.rb", "x\n")
      client = FakeClient.new { 0.1 }
      runner = runner([rule], client, cache: ".judgelint/cache.json")
      jobs = runner.plan(["app/a.rb"])
      write("app/a.rb", "y\n")

      error = assert_raises(Judgelint::Error) { runner.execute(jobs) }
      assert_equal "app/a.rb changed while judgelint ran; run it again", error.message
      assert_empty client.calls
      refute File.exist?(".judgelint/cache.json")
    end
  end

  def test_files_with_the_same_shape_share_their_questions
    in_project do
      write("app/a.rb", "x\n")
      write("app/b.rb", "y\n")
      jobs = runner([rule], FakeClient.new { 0.1 }).plan(%w[app/a.rb app/b.rb])

      assert_same jobs[0].questions, jobs[1].questions
    end
  end

  def test_rules_with_different_context_get_their_own_requests
    in_project do
      write("app/a.rb", "x\n")
      write("app/types.rb", "T\n")
      client = FakeClient.new { 0.1 }
      judge([rule("plain"), rule("typed", context: ["app/types.rb"])], client, ["app/a.rb"])

      calls = client.calls.sort_by(&:last)
      assert_equal [%w[plain.1-1], %w[typed.1-1]], calls.map(&:last)
      assert_includes calls.last.first, "Path: app/types.rb"
      refute_includes calls.first.first, "app/types.rb"
    end
  end

  def test_a_change_inside_a_directory_brings_the_directory_in
    in_project do
      write("app/features/a/index.rb", "x\n")
      write("app/features/b/index.rb", "x\n")
      client = FakeClient.new { 0.1 }
      rule = rule("cohesive", scope: "directory", paths: ["app/features/*"])
      judge([rule], client, [], directories: %w[app/features/a app/features/b],
                                changes: { "app/features/b/index.rb" => [1] })

      assert_equal 1, client.calls.size
      assert_includes client.calls.first.first, "Directory: app/features/b"
    end
  end

  def test_directory_examples_are_the_directories_under_pass_and_fail
    in_project do
      write(".judgelint/rules/cohesive/fail/orphan/index.rb", "x\n")
      write(".judgelint/rules/cohesive/fail/orphan/unused.rb", "SMELL\n")
      write(".judgelint/rules/cohesive/pass/tidy/index.rb", "x\n")
      rule = rule("cohesive", scope: "directory", paths: ["app/features/*"])
      client = FakeClient.new { |state, _question| state.include?("SMELL") ? 0.9 : 0.1 }
      runner = runner([rule], client)
      examples = runner.execute(runner.plan_examples).flatten

      assert_equal [true, true], examples.map(&:correct?)
      assert_equal(["Directory: tidy", "Directory: orphan"], client.calls.map { |state, _keys| state.lines.first.chomp })
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
      verdict = judge([rule], client, ["app/a.rb"], cache: ".judgelint/cache.json").first
      assert_equal :refused, verdict.status
      refute verdict.failing?

      judge([rule], client, ["app/a.rb"], cache: ".judgelint/cache.json")
      assert_equal 2, client.calls.size
    end
  end

  def test_a_file_over_the_token_budget_is_skipped_before_anything_is_sent
    in_project do
      write("app/a.rb", "x" * 400)
      client = FakeClient.new(max_state_tokens: 100) { 0.9 }
      runner = runner([rule], client)
      jobs = runner.plan(["app/a.rb"])

      assert_equal 0, runner.request_count(jobs)
      assert_equal :skipped, runner.execute(jobs).flatten.first.status
      assert_empty client.calls
    end
  end

  def test_packs_questions_by_tokens_and_count
    in_project do
      write("app/a.rb", "x\n" * 200)
      client = FakeClient.new(batch_size: 4) { 0.1 }
      runner = runner([rule("a"), rule("b")], client)
      jobs = runner.plan(["app/a.rb"])

      assert_equal [4, 4, 2], jobs.first.requests.map { |request| request.questions.size }
      assert_equal 3, runner.request_count(jobs)
      assert_equal jobs.first.requests.sum(&:tokens), runner.estimated_tokens(jobs)

      small = runner([rule("a"), rule("b")], FakeClient.new(max_request_tokens: 120) { 0.1 }).plan(["app/a.rb"])
      assert_operator small.first.requests.size, :>, 3
    end
  end

  def test_a_bullet_is_a_choice_with_the_specs_prose_and_names_its_line
    in_project do
      write("app/a.rb", "x\ny\nz\n")
      rule = Judgelint::Rule.new({ "convention" => "No smells.", "paths" => ["app/**/*.rb"] },
                                 source: "app/README.md", prose: "# Conventions\n\n- No smells.")
      client = FakeClient.new do |_state, question|
        question.where? ? { "L1" => 0.1, "L2" => 0.8, "L3" => 0.1 } : { "breaks" => 0.8, "follows" => 0.2, "not_applicable" => 0.0 }
      end
      verdict = judge([rule], client, ["app/a.rb"]).first

      state, keys = client.calls.first
      assert_equal %w[README.1-3 README.1-3.where], keys
      assert_equal({ "team_rules" => "# Conventions\n\n- No smells.", "file" => "Path: app/a.rb\n\n1: x\n2: y\n3: z\n" }, state)
      assert_equal [:violation, 0.8, [1, 3], 2], [verdict.status, verdict.probability, verdict.lines, verdict.line]
    end
  end

  def test_a_finding_names_a_line_only_when_the_models_agree_on_one
    in_project do
      write("app/a.rb", "x\ny\nz\n")
      rule = Judgelint::Rule.new({ "convention" => "No smells.", "paths" => ["app/**/*.rb"] }, source: "app/README.md")
      spread = { "L1" => 0.45, "L2" => 0.55, "L3" => 0.0 }
      client = FakeClient.new { |_state, question| question.where? ? spread : 0.9 }
      assert_equal 2, judge([rule], client, ["app/a.rb"]).first.line

      spread = { "L1" => 0.4, "L2" => 0.35, "L3" => 0.25 }
      verdict = judge([rule], FakeClient.new { |_state, question| question.where? ? spread : 0.9 }, ["app/a.rb"]).first
      assert_nil verdict.line, "no line has half"
      assert_equal [1, 3], verdict.lines
    end
  end

  def test_a_directory_finding_names_its_file
    in_project do
      write("app/feature/index.rb", "x\n")
      write("app/feature/stray.rb", "y\n")
      rule = Judgelint::Rule.new({ "convention" => "Every file is used.", "paths" => ["app/*"], "scope" => "directory" },
                                 source: "app/README.md")
      offered = nil
      client = FakeClient.new do |_state, question|
        offered = question.places if question.where?
        question.where? ? { "app/feature/index.rb" => 0.1, "app/feature/stray.rb" => 0.9 } : 0.9
      end
      runner = runner([rule], client)
      verdict = runner.execute(runner.plan([], directories: ["app/feature"])).flatten.first

      assert_equal %w[app/feature/index.rb app/feature/stray.rb], offered
      assert_equal ["app/feature/stray.rb", nil], [verdict.file, verdict.line]
    end
  end

  def test_every_model_is_asked_and_their_answers_averaged
    in_project do
      write("app/a.rb", "x\n" * 50)
      jev = FakeClient.new(model: "jev") { 0.9 }
      clef = FakeClient.new(model: "clef") { |_state, question| question.first == 1 ? 0.5 : nil }
      verdict = judge([rule], [jev, clef], ["app/a.rb"]).first

      assert_equal [%w[smell.1-40 smell.41-50]], jev.calls.map(&:last)
      assert_equal [%w[smell.1-40 smell.41-50]], clef.calls.map(&:last)
      assert_in_delta 0.9, verdict.probability, 0.001, "41-50: clef refused, so it's jev's 0.9 alone"
      assert_equal [41, 50], verdict.lines
    end
  end

  def test_each_models_answers_are_cached_on_their_own
    in_project do
      write("app/a.rb", "x")
      jev = FakeClient.new(model: "jev") { 0.2 }
      judge([rule], jev, ["app/a.rb"], cache: ".judgelint/cache.json")

      clef = FakeClient.new(model: "clef") { 0.8 }
      verdict = judge([rule], [jev, clef], ["app/a.rb"], cache: ".judgelint/cache.json").first

      assert_equal 1, jev.calls.size, "jev's answer came from the cache"
      assert_equal 1, clef.calls.size
      assert_in_delta 0.5, verdict.probability
    end
  end

  def test_a_files_requests_go_out_at_once
    in_project do
      write("app/a.rb", "x\n" * 200)
      started = Queue.new
      release = Queue.new
      client = FakeClient.new(batch_size: 2) do |_state, _question|
        started << true
        release.pop
        0.1
      end
      runner = runner([rule("a"), rule("b")], client)
      jobs = runner.plan(["app/a.rb"])
      worker = Thread.new { runner.execute(jobs) }
      5.times { Timeout.timeout(2) { started.pop } }

      assert_equal 5, jobs.first.requests.size, "all five requests were in flight before any returned"
      10.times { release << true }
      worker.join
    end
  end

  def test_a_judgehint_is_asked_about_for_its_window_only
    in_project do
      write("app/a.rb", ["# judgehint: the rescue re-raises after logging", *(["x"] * 59)].join("\n"))
      client = FakeClient.new { |_state, question| question.key.include?("41-60") ? 0.1 : 0.9 }
      verdict = judge([rule("smell")], client, ["app/a.rb"]).first

      assert_equal [%w[smell.1-40 smell.1-40.excused smell.41-60]], client.calls.map(&:last)
      assert_equal [:excused, [1, 40], 0.9], [verdict.status, verdict.lines, verdict.probability]
      assert verdict.as_example(:pass).correct?, "an excused example isn't a violation"
      refute verdict.as_example(:fail).correct?
    end
  end

  def test_a_judgehint_that_does_not_excuse_the_code_leaves_the_violation
    in_project do
      write("app/a.rb", "# judgehint: written quickly\nx\n")
      client = FakeClient.new { |_state, question| question.excuse? ? 0.2 : 0.9 }
      verdicts = judge([rule("smell")], client, ["app/a.rb"])

      assert_equal [:violation], verdicts.map(&:status)
    end
  end

  def test_a_violation_elsewhere_outranks_an_excused_window
    in_project do
      write("app/a.rb", ["# judgehint: intentional", *(["x"] * 59)].join("\n"))
      verdict = judge([rule("smell")], FakeClient.new { 0.9 }, ["app/a.rb"]).first

      assert_equal [:violation, [41, 60]], [verdict.status, verdict.lines]
    end
  end

  def test_judgehints_are_only_read_from_comments
    in_project do
      write("app/a.rb", %(raise "judgehint: not a comment"\n))
      client = FakeClient.new { 0.9 }
      judge([rule], client, ["app/a.rb"])

      refute(client.calls.flat_map(&:last).any? { |key| key.end_with?(".excused") })
    end
  end

  def test_cache_answers_repeat_runs_until_the_file_or_rule_changes
    in_project do
      write("app/a.rb", "x")
      client = FakeClient.new { 0.9 }
      cached = ".judgelint/cache.json"

      2.times { judge([rule], client, ["app/a.rb"], cache: cached) }
      assert_equal 1, client.calls.size

      write("app/a.rb", "y")
      judge([rule], client, ["app/a.rb"], cache: cached)
      assert_equal 2, client.calls.size

      judge([rule(question: "Reworded?")], client, ["app/a.rb"], cache: cached)
      assert_equal 3, client.calls.size

      judge([rule(severity: "warning", threshold: 0.9)], client, ["app/a.rb"], cache: cached)
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
      verdicts = judge([rule], client, paths)

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
      assert_equal(%w[bad.rb good.rb nested/also_bad.rb], client.calls.map { |state, _keys| state[/Path: (\S+)/, 1] }.sort)
    end
  end

  def test_bad_and_good_blocks_are_judged_like_example_files
    in_project do
      write("CONVENTIONS.md", <<~MARKDOWN)
        - **No smells.**

          Bad:

          ```ruby
          SMELL
          ```

          Good:

          ```ruby
          fine
          ```
      MARKDOWN
      rule = Judgelint::Spec.discover(rules_dir: ".judgelint/rules", default_threshold: 0.7).first
      client = FakeClient.new { |state, _question| state["file"].include?("SMELL") ? 0.9 : 0.1 }
      runner = runner([rule], client)
      examples = runner.execute(runner.plan_examples).flatten

      assert_equal [["CONVENTIONS.md:6", :fail, true], ["CONVENTIONS.md:12", :pass, true]],
                   examples.map { |example| [example.path, example.expected, example.correct?] }
      assert_equal(%w[example.ruby example.ruby], client.calls.map { |state, _keys| state["file"][/Path: (\S+)/, 1] })

      File.write("CONVENTIONS.md", File.read("CONVENTIONS.md").sub("Good:", "Bad:"))
      rule = Judgelint::Spec.discover(rules_dir: ".judgelint/rules", default_threshold: 0.7).first
      error = assert_raises(Judgelint::ConfigError) { runner([rule], client).plan_examples }
      assert_match(%r{add a Good block under root/no-smells}, error.message)
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

  def runner(rules, clients, cache: nil)
    Judgelint::Runner.new(config: config, rules: rules, clients: Array(clients), cache: Judgelint::Cache.new(cache))
  end

  def judge(rules, clients, paths, cache: nil, changes: nil, directories: [])
    runner = runner(rules, clients, cache: cache)
    runner.execute(runner.plan(paths, directories: directories, changes: changes)).flatten
  end
end
