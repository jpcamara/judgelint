# frozen_string_literal: true

require "test_helper"
require "open3"

# More CLI cases: changed lines under --base, symlinks, colors, and example
# line numbers.
class MoreCLITest < Minitest::Test
  include ProjectHelpers

  def setup
    @server = StubSystemOne.new
  end

  def teardown
    @server.stop
  end

  def test_a_window_rule_asks_about_the_changed_lines_alone
    in_smelly_project do
      write_rule("whole", extra: "scope: file")
      write("app/a.rb", "x\n" * 130)
      git_repo
      write("app/a.rb", (1..130).map { |n| [43, 45, 46, 125].include?(n) ? "y\n" : "x\n" }.join)
      runners.each do |name, run|
        @server.requests.clear
        run.call(["--base", "main"])
        asked = @server.requests.flat_map { |request| request[:payload]["questions"].values }
                       .map { |question| question["instructions"][/\ALook at [^;]+/] }

        assert_equal ["Look at lines 43, 45-46 of the file", "Look at line 125 of the file", nil], asked, name
      end
    end
  end


  def test_a_finding_on_a_line_the_change_didnt_touch_passes
    in_project do
      write("app/README.md", <<~MARKDOWN)
        ---
        paths: ["app/**/*.rb"]
        ---
        - **No smells.** Code here doesn't smell.
      MARKDOWN
      write("app/a.rb", "SMELL\n" * 50)
      git_repo
      runners.each do |name, run|
        # The where answer puts the finding on the window's first line, L41.
        git("checkout", "-q", "--", "app/a.rb")
        write("app/a.rb", (1..50).map { |n| n == 45 ? "SMELL!\n" : "SMELL\n" }.join)
        status, out, = run.call(["--base", "main", "-f", "json"])
        untouched = JSON.parse(out)["results"].first

        assert_equal [0, "pass", 0.0], [status, untouched["status"], untouched["probability"]], name
        verdict = @server.requests.last[:payload]["questions"].values.first
        assert_equal "How does line 45 of the file relate to the following team rule? Rule: No smells. Code here doesn't smell.", verdict["instructions"], name

        write("app/a.rb", (1..50).map { |n| n == 41 ? "SMELL!\n" : "SMELL\n" }.join)
        status, out, = run.call(["--base", "main", "-f", "json"])
        touched = JSON.parse(out)["results"].first

        assert_equal [1, "violation", 41], [status, touched["status"], touched["line"]], name
      end
    end
  end


  def test_symlinks_count_as_what_they_lead_to
    in_smelly_project do
      File.symlink("bad.rb", "app/alias.rb")
      File.symlink("nowhere.rb", "app/gone.rb")
      File.symlink(".", "app/loop")
      File.symlink("app", "linked")
      write(".judgelint/rules/linked.md", "---\nquestion: Does this code smell?\npaths: [\"linked/*.rb\"]\n---\n" \
                                          "Smelly code is hard to change.\n")
      runners.each do |name, run|
        status, out, = run.call([])

        assert_equal 1, status, name
        assert_match(%r{^app/alias\.rb\n  x error\s+smell }, out, "#{name}: a link to a file is the file")
        assert_match(%r{^linked/bad\.rb\n}, out, "#{name}: a literal segment goes through a link")
        refute_match(%r{app/loop/}, out, "#{name}: `**/` doesn't enter a link")
        assert_match(/^6 files, 4 violations$/, out, name)
      end
    end
  end


  def test_color_follows_force_color_and_no_color
    in_smelly_project do
      runners.each do |name, run|
        _status, out, err = run.call(["app/bad.rb"], extra_env: { "FORCE_COLOR" => "1" })

        assert_includes out, "\e[1mapp/bad.rb\e[0m\n", name
        assert_includes out, "\e[1;31m\u2717 error\e[0m", name
        assert_includes out, "\e[1;31m1 violations\e[0m", name
        assert_match(/\A\e\[2mjudgelint: 1 request, /, err, name)

        status, out, err = run.call(["--format", "nope"], extra_env: { "FORCE_COLOR" => "1" })
        assert_equal 2, status, name
        assert_empty out, name
        assert_match(/nope/, err, name)

        _status, out, = run.call(["app/bad.rb"], extra_env: { "FORCE_COLOR" => "1", "NO_COLOR" => "1" })
        refute_includes out, "\e[", name
        _status, out, = run.call(["app/bad.rb"])
        refute_includes out, "\e[", "#{name}: piped output stays plain"
      end
    end
  end


  def test_example_lines_count_the_frontmatter
    in_project do
      write("CONVENTIONS.md", "---\npaths: [\"**/*.rb\"]\n---\n- **No smells.**\n\n  Bad:\n\n  ```ruby\n  SMELL\n  ```\n")
      write("CONVENTIONS.md", File.read("CONVENTIONS.md") + "\n  Good:\n\n  ```ruby\n  fine\n  ```\n")
      runners.each do |name, run|
        _status, out, = run.call(["test"])

        assert_match(/^  ok   fail 0\.90  CONVENTIONS\.md:9$/, out, name)
        assert_match(/^  MISS pass 0\.90  CONVENTIONS\.md:15$/, out, name)
      end
    end
  end

  def test_pr_reads_the_base_branch_from_each_ci
    in_smelly_project do |dir|
      git_repo
      git("branch", "develop")
      git("branch", "trunk")
      git("init", "--bare", "-q", "#{dir}/origin.git")
      git("remote", "add", "origin", "#{dir}/origin.git")
      git("push", "-q", "origin", "main", "develop", "trunk")
      write("app/good.rb", "SMELL\n")
      unset = %w[JUDGELINT_BASE_BRANCH GITHUB_BASE_REF CI_MERGE_REQUEST_TARGET_BRANCH_NAME
                 BUILDKITE_PULL_REQUEST_BASE_BRANCH BITBUCKET_PR_DESTINATION_BRANCH
                 SYSTEM_PULLREQUEST_TARGETBRANCH].to_h { |name| [name, nil] }
      # Azure names a full ref, and Buildkite says "false" outside a pull request.
      [{ "SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/develop" },
       { "BUILDKITE_PULL_REQUEST_BASE_BRANCH" => "false", "SYSTEM_PULLREQUEST_TARGETBRANCH" => "trunk" },
       { "JUDGELINT_BASE_BRANCH" => "trunk", "GITHUB_BASE_REF" => "nowhere" }].each do |ci|
        status, out, err = judgelint("--pr", env: unset.merge(ci))

        assert_equal 1, status, "#{ci}: #{err}"
        assert_match(/^1 file, 1 violations$/, out, ci.to_s)
      end
    end
  end

  private

  def runners
    { "rust" => ->(args, **opts) { run_command([BINARY], args, **opts) } }
  end

  # Always called inside a temporary project. The config asks the stub
  # server, as Jev, with +model+'s settings on top; +config+ adds top-level
  # settings. JSON is YAML. Every run passes --no-cache.
  def env(api_base, model, config)
    entry = { "provider" => "typesafe", "api_base" => api_base, "api_key_env" => "JUDGELINT_TEST_KEY" }.merge(model)
    write(".judgelint.yml", JSON.generate({ "models" => [entry] }.merge(config)))
    { "JUDGELINT_TEST_KEY" => "secret" }
  end

  def run_command(command, args, api_base: @server.base, model: {}, config: {}, extra_env: {})
    out, err, status = Open3.capture3(env(api_base, model, config).merge(extra_env), *command, *args, "--no-cache")
    [status.exitstatus, out, err]
  end
end
