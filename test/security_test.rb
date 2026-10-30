# frozen_string_literal: true

require "test_helper"
require "open3"
require "fileutils"

# What a project's files can make judgelint read, send, or trust.
class SecurityTest < Minitest::Test
  include ProjectHelpers

  def setup
    @server = StubSystemOne.new
  end

  def teardown
    @server.stop
  end

  def test_context_outside_the_project_is_an_error
    Dir.mktmpdir("judgelint-outside") do |outside|
      secret = File.join(outside, "secret.txt")
      File.write(secret, "OUTSIDE\n")
      in_smelly_project do
        write_rule("smell", extra: "context: [\"#{secret}\"]")
        status, _out, err = judgelint("app/bad.rb")

        assert_equal 2, status
        assert_match(/outside the project/, err)
        assert_empty @server.requests
      end
    end
  end

  def test_a_link_out_of_the_project_is_left_out
    Dir.mktmpdir("judgelint-outside") do |outside|
      File.write(File.join(outside, "linked.rb"), "OUTSIDE\n")
      in_smelly_project do
        File.symlink(File.join(outside, "linked.rb"), "app/innocent.rb")
        status, _out, err = judgelint

        assert_equal 1, status, err
        assert_match(%r{left out app/innocent\.rb is outside the project}, err)
        refute(@server.requests.any? { |r| r[:payload].to_s.include?("OUTSIDE") })
      end
    end
  end

  def test_a_link_within_the_project_is_followed
    in_smelly_project do
      File.symlink("bad.rb", "app/also_bad.rb")
      status, out, err = judgelint

      assert_equal 1, status, err
      assert_match(/^3 files, 2 violations$/, out)
    end
  end

  def test_a_config_that_leads_outside_the_project_is_an_error
    Dir.mktmpdir("judgelint-outside") do |outside|
      File.write(File.join(outside, "secret.yml"), "token: OUTSIDE\n")
      in_smelly_project do
        File.symlink(File.join(outside, "secret.yml"), ".judgelint.yml")
        _out, err, status = Open3.capture3(BINARY, "app/bad.rb", "--no-cache")

        assert_equal 2, status.exitstatus
        assert_match(/\.judgelint\.yml is outside the project/, err)
        refute_includes err, "OUTSIDE"
      end
    end
  end

  def test_git_failing_to_list_the_files_is_an_error
    in_smelly_project do
      write("config/master.key", "SMELL\n")
      write(".gitignore", "master.key\n")
      git_repo
      File.write(".git/index", "not an index")
      status, _out, err = judgelint

      assert_equal 2, status
      assert_match(/git couldn't list the project's files/, err)
      assert_empty @server.requests
    end
  end

  def test_a_pipe_named_as_context_is_an_error_not_a_wait
    in_smelly_project do
      File.mkfifo("app/pipe")
      write_rule("smell", extra: "context: [\"app/pipe\"]")
      status, _out, err = judgelint("app/bad.rb")

      assert_equal 2, status
      assert_match(%r{app/pipe isn't a regular file}, err)
    end
  end

  def test_a_directory_rule_sends_neither_ignored_nor_binary_files
    in_project do
      write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                            "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
      write("app/features/a/index.rb", "fine\n")
      write("app/features/a/master.key", "IGNORED-SECRET\n")
      File.binwrite("app/features/a/blob.bin", "BINARY\0SECRET")
      write(".gitignore", "master.key\n")
      git_repo
      judgelint

      sent = @server.requests.map { |r| r[:payload].to_s }.join
      assert_includes sent, "app/features/a/index.rb"
      refute_includes sent, "IGNORED-SECRET"
      refute_includes sent, "BINARY"
    end
  end

  def test_pr_uses_the_base_branchs_config_and_its_own_rules_and_cache
    attacker = StubSystemOne.new { 0.0 }
    in_smelly_project do |dir|
      write_config
      git_repo
      git("init", "--bare", "-q", "#{dir}/origin.git")
      git("remote", "add", "origin", "#{dir}/origin.git")
      git("push", "-q", "origin", "main")
      git("checkout", "-q", "-b", "change")
      write("app/new.rb", "SMELL\n")
      write_rule("smell", extra: "context: [\"app/good.rb\"]")
      write(".judgelint/cache.bin", "jlcache1")
      write_config(server: attacker, model: { "api_key_env" => "AWS_SECRET_ACCESS_KEY" })
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "change")
      out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "AWS_SECRET_ACCESS_KEY" => "aws",
                                          "GITHUB_BASE_REF" => "main" }, BINARY, "--pr")

      assert_equal 1, status.exitstatus, err
      assert_match(/^1 file, 1 violations$/, out)
      assert_empty attacker.requests, "the pull request's config isn't used"
      assert_equal ["Bearer secret"], @server.requests.map { |r| r[:authorization] }
      assert_includes @server.requests.first[:payload].to_s, "Context", "but its rules are"
      assert_operator File.size(".judgelint/cache.bin"), :>, 8, "and its cache"
    end
  ensure
    attacker&.stop
  end

  def commit_all(message)
    git("add", "-A")
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", message)
  end

  # Merges +branch+ into HEAD, detached, as GitHub makes a pull request's
  # merge commit. Returns the merge.
  def github_merge(onto, branch)
    git("checkout", "-q", "--detach", onto)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "--no-ff", "-q", "-m", "Merge", branch)
    head
  end

  def head
    Open3.capture2("git", "rev-parse", "HEAD").first.strip
  end

  # --pr in GitHub Actions' run for pull request 7, whose merge commit is +sha+.
  def pr_on_github(sha, env = {})
    out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "GITHUB_EVENT_NAME" => "pull_request",
                                        "GITHUB_REF" => "refs/pull/7/merge", "GITHUB_SHA" => sha }.merge(env),
                                      BINARY, "--pr")
    [status.exitstatus, out, err]
  end

  def test_pr_on_githubs_merge_commit_compares_with_its_first_parent
    attacker = StubSystemOne.new
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("remote", "add", "origin", origin)
        git("checkout", "-q", "-b", "change")
        write("app/new.rb", "SMELL\n")
        write_config(server: attacker)
        commit_all("change")
        git("checkout", "-q", "main")
        write("app/later.rb", "SMELL\n")
        commit_all("main moves on")
        merge = github_merge("main", "change")
        # A base branch it would fail to fetch, to show it isn't used.
        status, out, err = pr_on_github(merge, "GITHUB_BASE_REF" => "nowhere")

        assert_equal 1, status, err
        assert_match(/^1 file, 1 violations$/, out, "only the pull request's file, not main's")
        assert_empty attacker.requests, "with the first parent's config"
        refute_empty @server.requests
      end
    end
  ensure
    attacker&.stop
  end

  def test_a_stacked_pr_on_githubs_merge_commit_is_only_its_own_changes
    in_smelly_project do
      write_config
      git_repo
      git("checkout", "-q", "-b", "below")
      write("app/one.rb", "SMELL\n")
      commit_all("below")
      git("checkout", "-q", "-b", "above")
      write("app/two.rb", "SMELL\n")
      commit_all("above")
      git("checkout", "-q", "main")
      write("app/later.rb", "SMELL\n")
      commit_all("main moves on")
      below = github_merge("main", "below")
      # GitHub builds the merge on the merge of the pull request below.
      merge = github_merge(below, "above")
      status, out, err = pr_on_github(merge, "GITHUB_BASE_REF" => "main")

      assert_equal 1, status, err
      assert_match(/^1 file, 1 violations$/, out)
    end
  end

  def test_a_merge_the_pr_committed_isnt_taken_for_githubs
    attacker = StubSystemOne.new
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("remote", "add", "origin", origin)
        git("checkout", "-q", "-b", "change")
        write_config(server: attacker)
        commit_all("change the config")
        git("checkout", "-q", "main")
        write("app/later.rb", "fine\n")
        commit_all("main moves on")
        git("push", "-q", "origin", "main")
        git("checkout", "-q", "change")
        write("app/new.rb", "SMELL\n")
        commit_all("change")
        # The pull request merges main into itself, and its head is checked out.
        git("-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "--no-ff", "-q", "-m", "Merge main", "main")
        status, out, err = pr_on_github("0" * 40, "GITHUB_BASE_REF" => "main")

        assert_equal 1, status, err
        assert_match(/^1 file, 1 violations$/, out)
        assert_empty attacker.requests, "its first parent's config is the pull request's"
      end
    end
  ensure
    attacker&.stop
  end

  def test_pr_takes_the_branch_a_stacked_pr_targets_from_githubs_event
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("remote", "add", "origin", origin)
        git("checkout", "-q", "-b", "below")
        write("app/one.rb", "SMELL\n")
        commit_all("below")
        git("push", "-q", "origin", "main", "below")
        git("checkout", "-q", "-b", "above")
        write("app/two.rb", "SMELL\n")
        commit_all("above")
        event = File.join(origin, "event.json")
        File.write(event, JSON.generate({ "pull_request" => { "base" => { "ref" => "below" } } }))
        # The head is checked out, so GitHub's merge commit isn't HEAD.
        status, out, err = pr_on_github("0" * 40, "GITHUB_BASE_REF" => "main", "GITHUB_EVENT_PATH" => event)

        assert_equal 1, status, err
        assert_match(/^1 file, 1 violations$/, out, "not the stack's two")
      end
    end
  end

  def test_pr_on_a_shallow_checkout_of_githubs_merge_commit_fetches_its_parents
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do |dir|
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("checkout", "-q", "-b", "change")
        write("app/new.rb", "SMELL\n")
        commit_all("change")
        merge = github_merge("main", "change")
        git("push", "-q", origin, "HEAD:refs/pull/7/merge")
        # Like actions/checkout: one commit deep, fetched by its ref.
        checkout = File.join(dir, "checkout")
        Dir.mkdir(checkout)
        Dir.chdir(checkout) do
          git("init", "-q")
          git("remote", "add", "origin", "file://#{origin}")
          git("fetch", "-q", "--depth=1", "origin", "+refs/pull/7/merge:refs/remotes/pull/7/merge")
          git("checkout", "-q", "--detach", merge)
          status, out, err = pr_on_github(merge)

          assert_equal 1, status, err
          assert_match(/^1 file, 1 violations$/, out)
        end
      end
    end
  end

  def test_pr_works_in_a_clone_of_one_branch
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do |dir|
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("checkout", "-q", "-b", "change")
        write("app/new.rb", "SMELL\n")
        commit_all("change")
        git("push", "-q", origin, "main", "change")
        checkout = File.join(dir, "checkout")
        git("clone", "-q", "--single-branch", "--branch", "change", "file://#{origin}", checkout)
        Dir.chdir(checkout) do
          out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "GITHUB_BASE_REF" => "main" },
                                            BINARY, "--pr")

          assert_equal 1, status.exitstatus, err
          assert_match(/^1 file, 1 violations$/, out)
        end
      end
    end
  end

  def test_pr_without_the_history_says_to_fetch_it
    Dir.mktmpdir("judgelint-origin") do |origin|
      in_smelly_project do |dir|
        write_config
        git_repo
        git("init", "--bare", "-q", origin)
        git("checkout", "-q", "-b", "change")
        write("app/new.rb", "SMELL\n")
        commit_all("change")
        git("push", "-q", origin, "main", "change")
        checkout = File.join(dir, "checkout")
        git("clone", "-q", "--depth=1", "--branch", "change", "file://#{origin}", checkout)
        Dir.chdir(checkout) do
          _out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "GITHUB_BASE_REF" => "main" },
                                             BINARY, "--pr")

          assert_equal 2, status.exitstatus, err
          assert_match(/fetch more history, like fetch-depth: 0/, err)
          assert_empty @server.requests
        end
      end
    end
  end

  def test_base_and_pr_only_work_with_check
    in_smelly_project do
      [%w[test --pr], %w[--pr test], %w[rules --base main], %w[--base main rules]].each do |args|
        status, _out, err = judgelint(*args)

        assert_equal 2, status, args.join(" ")
        assert_match(/--pr|--base/, err, args.join(" "))
      end
      assert_empty @server.requests
    end
  end

  def test_pr_judges_its_commits_not_whatever_else_is_in_the_checkout
    in_smelly_project do |dir|
      write(".gitignore", "app/local.rb\n")
      write_config
      git_repo
      git("init", "--bare", "-q", "#{dir}/origin.git")
      git("remote", "add", "origin", "#{dir}/origin.git")
      git("push", "-q", "origin", "main")
      git("checkout", "-q", "-b", "change")
      # The pull request un-ignores a file an earlier CI step wrote.
      write(".gitignore", "")
      git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qam", "un-ignore")
      write("app/local.rb", "SMELL TOKEN=hunter2\n")
      write("app/good.rb", "SMELL uncommitted\n")
      out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "GITHUB_BASE_REF" => "main" },
                                        BINARY, "--pr")

      assert_equal 0, status.exitstatus, err
      assert_match(/^0 files, 0 violations$/, out)
      assert_empty @server.requests
    end
  end

  def test_pr_asks_again_only_about_what_a_push_changed
    in_smelly_project do |dir|
      write_config
      git_repo
      git("init", "--bare", "-q", "#{dir}/origin.git")
      git("remote", "add", "origin", "#{dir}/origin.git")
      git("push", "-q", "origin", "main")
      git("checkout", "-q", "-b", "change")
      write("app/new.rb", "SMELL\n")
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "change")
      env = { "JUDGELINT_TEST_KEY" => "secret", "GITHUB_BASE_REF" => "main" }
      Open3.capture3(env, BINARY, "--pr")
      asked = @server.requests.size
      _out, err, status = Open3.capture3(env, BINARY, "--pr")

      assert_equal 1, status.exitstatus, err
      assert_operator asked, :>, 0
      assert_equal asked, @server.requests.size, "the second run's answers are cached"
    end
  end

  def test_a_changed_link_out_of_the_project_fails_a_change_check
    Dir.mktmpdir("judgelint-outside") do |outside|
      File.write(File.join(outside, "linked.rb"), "OUTSIDE\n")
      in_smelly_project do
        git_repo
        File.symlink(File.join(outside, "linked.rb"), "app/innocent.rb")
        status, out, err = judgelint("--base", "main")

        assert_equal 1, status, err
        assert_match(/skipped/, out)
        assert_empty @server.requests
      end
    end
  end

  def test_a_directory_with_a_file_too_large_to_send_is_skipped
    in_project do
      write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                            "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
      write("app/features/a/index.rb", "fine\n")
      git_repo
      write("app/features/a/huge.rb", "x" * (5 << 20))
      status, out, err = judgelint("--base", "main")

      assert_equal 1, status, err
      assert_match(/skipped/, out)
      assert_empty @server.requests
    end
  end

  def test_a_directory_with_a_link_out_of_the_project_is_skipped
    Dir.mktmpdir("judgelint-outside") do |outside|
      File.write(File.join(outside, "linked.rb"), "OUTSIDE\n")
      in_project do
        write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                              "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
        write("app/features/a/index.rb", "fine\n")
        git_repo
        File.symlink(File.join(outside, "linked.rb"), "app/features/a/linked.rb")
        status, out, err = judgelint("--base", "main")

        assert_equal 1, status, err
        assert_match(/skipped/, out)
        assert_empty @server.requests
      end
    end
  end

  def test_a_changed_file_with_a_nul_byte_fails_a_change_check
    in_smelly_project do
      git_repo
      write("app/sneaky.rb", "# \0\nSMELL\n")
      status, out, err = judgelint("--base", "main")

      assert_equal 1, status, err
      assert_match(/skipped app\/sneaky\.rb is binary/, err)
      assert_match(/1 skipped/, out)
      assert_empty @server.requests
    end
  end

  def test_a_changed_image_is_left_out
    in_project do
      write(".judgelint/rules/any.md", "---\nquestion: Does this code smell?\npaths: [\"app/**/*\"]\n---\nAnything.\n")
      write("app/a.rb", "fine\n")
      git_repo
      File.binwrite("app/logo.png", "\x89PNG\r\n\x1a\n\0\0\0\rIHDR")
      status, out, err = judgelint("--base", "main")

      assert_equal 0, status, err
      assert_match(/^0 files, 0 violations$/, out)
    end
  end

  def test_a_window_the_model_refuses_leaves_the_rule_refused
    @server.stop
    @server = StubSystemOne.new { |_state, key| key.end_with?("41-80") ? nil : 0.1 }
    in_project do
      write_rule("smell")
      write("app/a.rb", "fine\n" * 80)
      git_repo
      File.write("app/a.rb", "changed\n" * 80)
      status, out, err = judgelint("--base", "main")

      assert_equal 1, status, err
      assert_match(/1 refused/, out)
      assert_match(/were skipped or refused, so the run fails/, err)
    end
  end

  def test_deleting_a_file_asks_about_its_directory
    in_project do
      write(".judgelint/rules/cohesive.md", "---\nquestion: Do these files fail to hang together?\nscope: directory\n" \
                                            "paths: [\"app/features/*\"]\n---\nOne capability per feature.\n")
      write("app/features/a/index.rb", "fine\n")
      write("app/features/a/helper.rb", "fine\n")
      git_repo
      File.delete("app/features/a/helper.rb")
      judgelint("--base", "main")

      assert_equal 1, @server.requests.size
    end
  end

  def test_an_empty_file_is_still_asked_about
    in_project do
      write_rule("exports", question: "Does this file export something?", extra: "fail_when: no")
      git_repo
      write("app/empty.rb", "")
      status, = judgelint("--base", "main")

      assert_equal 1, status
      assert_equal 1, @server.requests.size
    end
  end

  def write_directory_rule
    write(".judgelint/rules/no-smell.md", <<~MARKDOWN)
      ---
      question: Does any file in this directory smell?
      scope: directory
      paths: ["app/*"]
      ---
      No smells.
    MARKDOWN
  end

  def test_a_link_to_a_directory_that_a_change_adds_is_judged
    in_project do
      write_directory_rule
      write("app/a/index.rb", "fine\n")
      write("vendor/ok.rb", "fine\n")
      git_repo
      write("vendor/bad.rb", "SMELL\n")
      File.symlink("../vendor", "app/payments")
      status, out, err = judgelint("--base", "main")

      assert_equal 1, status, err
      assert_match(/^app\/payments$/, out)
    end
  end

  def test_a_directory_named_like_a_pattern_sends_its_own_files
    in_project do
      write_directory_rule
      write("app/pay[1]/bad.rb", "SMELL\n")
      write("app/pay1/ok.rb", "fine\n")
      status, out, err = judgelint

      assert_equal 1, status, err
      assert_match(/^app\/pay\[1\]$/, out)
      refute_match(/^app\/pay1$/, out)
    end
  end

  def test_ci_commands_in_file_names_are_escaped_in_every_format
    in_smelly_project do
      write("app/##vso[task.complete]##[error]x.rb", "SMELL\n")
      _status, text, = judgelint
      _status, json, = judgelint("-f", "json")
      _status, sarif, = judgelint("-f", "sarif")

      [text, json, sarif].each { |out| refute_includes out, "##" }
      assert_includes text, "app/#\\#vso[task.complete]#\\#[error]x.rb"
      assert_includes JSON.parse(json)["results"].map { |r| r["path"] }, "app/##vso[task.complete]##[error]x.rb"
      uris = JSON.parse(sarif)["runs"][0]["results"].map { |r| r["locations"][0]["physicalLocation"]["artifactLocation"]["uri"] }
      assert_includes uris, "app/##vso[task.complete]##[error]x.rb"
    end
  end

  def test_a_changed_path_that_isnt_utf8_fails_a_change_check
    skip "file names are UTF-8 on macOS" unless RUBY_PLATFORM.include?("linux")
    in_smelly_project do
      git_repo
      # Decoded with a stand-in for the bad byte, the changed file would be
      # the empty one beside it.
      write("app/\uFFFD.rb", "")
      write("app/\xFF.rb".b, "SMELL\n")
      status, _out, err = judgelint("--base", "main")

      assert_equal 2, status, err
      assert_match(/can only read paths in UTF-8/, err)
      assert_empty @server.requests
    end
  end

  def test_init_leaves_a_link_alone
    Dir.mktmpdir("judgelint-outside") do |outside|
      in_project do
        File.symlink(File.join(outside, "created.md"), "CONVENTIONS.md")
        out, _err, status = Open3.capture3(BINARY, "init")

        assert_equal 0, status.exitstatus
        assert_match(/exists  CONVENTIONS\.md/, out)
        refute File.exist?(File.join(outside, "created.md"))
      end
    end
  end

  def test_a_file_gitattributes_marks_binary_is_still_checked_when_changed
    in_smelly_project do
      write(".gitattributes", "*.rb -diff\n")
      git_repo
      write("app/good.rb", "SMELL\n")
      status, out, = judgelint("--base", "main")

      assert_equal 1, status
      assert_match(/^1 file, 1 violations$/, out)
    end
  end

  def test_a_local_server_named_through_a_variable_costs_nothing
    in_smelly_project do
      port = @server.base[/\d+\z/]
      model = { "provider" => "custom", "model" => "m", "api_base" => "http://127.0.0.1:${JUDGELINT_PORT}", "auth" => "none" }
      status, _out, err = judgelint("app/bad.rb", model: model, env: { "JUDGELINT_PORT" => port })

      assert_equal 1, status, err
    end
  end

  def test_a_change_too_large_to_judge_fails_the_check
    in_smelly_project do
      git_repo
      write("app/big.rb", "SMELL\n#{'x' * 2000}\n")
      config = { "models" => [{ "provider" => "typesafe", "api_base" => @server.base,
                                "api_key_env" => "JUDGELINT_TEST_KEY", "max_state_tokens" => 200 }] }
      status, out, err = judgelint("--base", "main", config: config)

      assert_equal 1, status, err
      assert_match(/skipped/, out)
      assert_match(/were skipped or refused, so the run fails/, err)

      status, = judgelint("app/big.rb", config: config)
      assert_equal 0, status, "outside a change, a skipped file is only reported"
    end
  end

  def test_an_added_line_that_looks_like_a_diff_header_hides_nothing
    in_project do
      write_rule("smell")
      write("app/a.rb", "#{"fine\n" * 60}")
      git_repo
      lines = File.readlines("app/a.rb")
      lines[1] = "++ b/app/elsewhere.rb\n"
      lines[54] = "SMELL\n"
      File.write("app/a.rb", lines.join)
      status, = judgelint("--base", "main")

      assert_equal 1, status
      assert_equal [%w[smell.1-40 smell.41-60]], @server.requests.map { |r| r[:payload]["questions"].keys.sort },
                   "line 55 is still asked about"
    end
  end

  def test_a_header_variable_pointing_elsewhere_asks_again
    in_smelly_project do
      model = { "provider" => "custom", "model" => "m", "auth" => "none", "headers" => { "X-Backend" => "${JUDGELINT_BACKEND}" } }
      %w[a b].each do |backend|
        status, _out, err = judgelint("app/bad.rb", model: model, env: { "JUDGELINT_BACKEND" => backend }, cache: true)
        assert_equal 1, status, err
      end

      assert_equal %w[a b], @server.requests.map { |r| r[:headers]["x-backend"] }
    end
  end

  def test_a_changed_link_to_nothing_fails_a_change_check
    in_smelly_project do
      git_repo
      File.symlink("missing.rb", "app/gone.rb")
      status, out, err = judgelint("--base", "main")

      assert_equal 1, status, err
      assert_match(%r{skipped app/gone\.rb doesn't lead to a file}, err)
      assert_match(/1 skipped/, out)
    end
  end

  def test_pr_judges_a_changed_file_as_committed
    in_smelly_project do |dir|
      write_config
      git_repo
      git("init", "--bare", "-q", "#{dir}/origin.git")
      git("remote", "add", "origin", "#{dir}/origin.git")
      git("push", "-q", "origin", "main")
      git("checkout", "-q", "-b", "change")
      write("app/new.rb", "SMELL\n")
      git("add", "-A")
      git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "change")
      # A step before the check writes over it.
      write("app/new.rb", "fine\n")
      out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret", "GITHUB_BASE_REF" => "main" },
                                        BINARY, "--pr")

      assert_equal 1, status.exitstatus, err
      assert_match(/^1 file, 1 violations$/, out)
    end
  end

  def test_a_variable_pointing_elsewhere_asks_again
    other = StubSystemOne.new
    in_smelly_project do
      model = { "provider" => "custom", "model" => "m", "api_base" => "http://127.0.0.1:${JUDGELINT_PORT}", "auth" => "none" }
      [@server, other].each do |server|
        status, _out, err = judgelint("app/bad.rb", model: model, env: { "JUDGELINT_PORT" => server.base[/\d+\z/] },
                                                    cache: true)
        assert_equal 1, status, err
      end

      assert_equal [1, 1], [@server.requests.size, other.requests.size]
    end
  ensure
    other&.stop
  end

  def test_a_model_without_a_price_needs_yes
    in_smelly_project do
      model = { "provider" => "custom", "model" => "m", "api_base" => "https://judge.example.invalid", "auth" => "none" }
      status, _out, err = judgelint("app/bad.rb", model: model)

      assert_equal 2, status
      assert_match(/custom:m, which has no price.*--yes/, err)
    end
  end

  def test_a_failing_request_stops_the_rest_of_its_files_requests
    @server.stop
    @server = StubSystemOne.new(status: 400, body: "{}")
    in_project do
      write_rule("smell")
      write("app/long.rb", "fine\n" * 3000)
      status, _out, err = judgelint(model: { "batch_size" => 1 })

      assert_equal 2, status, err
      assert_operator @server.requests.size, :<, 75, "75 windows, a request each"
    end
  end

  def test_a_failing_endpoint_stops_the_run
    @server.stop
    @server = StubSystemOne.new(status: 400, body: "{}")
    in_project do
      write_rule("smell")
      300.times { |i| write("app/f#{i}.rb", "fine #{i}\n") }
      status, _out, err = judgelint

      assert_equal 2, status, err
      assert_operator @server.requests.size, :<, 300
    end
  end

  def test_a_file_of_short_lines_is_skipped_before_its_questions_are_made
    in_project do
      write_rule("smell")
      write("app/lines.rb", "\n" * 3_000_000)
      status, out, err = judgelint

      assert_equal 0, status, err
      assert_match(/1 skipped/, out)
      assert_empty @server.requests
    end
  end

  def test_a_retry_after_that_isnt_a_number_is_ignored
    @server.stop
    @server = StubSystemOne.new(responses: [[429, "{}", { "Retry-After" => "NaN" }], [200, nil]])
    in_smelly_project do
      status, _out, err = judgelint("app/bad.rb")

      assert_equal 1, status, err
      assert_equal 2, @server.requests.size
    end
  end

  def test_a_file_name_cant_forge_a_line_of_output
    in_smelly_project do
      write("app/a\n::error file=app/good.rb::forged.rb", "SMELL\n")
      status, out, err = judgelint

      assert_equal 1, status, err
      assert_includes out, "app/a\\n::error"
      refute_match(/^::error/, out)
    end
  end

  def test_an_endpoints_error_cant_forge_a_line_of_output
    @server.stop
    @server = StubSystemOne.new(status: 400, body: JSON.generate({ "detail" => "bad\n::error::forged\e[31m ##[error]x" }))
    in_smelly_project do
      status, _out, err = judgelint("app/bad.rb")

      assert_equal 2, status
      assert_includes err, 'bad\n::error::forged\u{1b}[31m #\#[error]x'
      refute_match(/^::error/, err)
    end
  end

  def test_a_file_name_cant_be_a_workflow_command
    in_project do
      write(".judgelint/rules/any.md", "---\nquestion: Does this code smell?\npaths: [\"**/*.rb\"]\n---\nAnything.\n")
      write("::error::forged.rb", "SMELL\n")
      status, out, err = judgelint

      assert_equal 1, status, err
      assert_includes out, '\::error::forged.rb'
      refute_match(/^::/, out)
    end
  end

  def test_redirects_arent_followed
    elsewhere = StubSystemOne.new
    @server.stop
    @server = StubSystemOne.new(responses: [[302, "{}", { "Location" => "#{elsewhere.base}/v1/systemone" }]])
    in_smelly_project do
      status, _out, err = judgelint("app/bad.rb", model: { "auth" => "header:api-key" })

      assert_equal 2, status
      assert_match(/answered 302/, err)
      assert_empty elsewhere.requests
    end
  ensure
    elsewhere&.stop
  end

  def test_errors_show_the_url_as_configured
    in_smelly_project do
      model = { "api_base" => "http://127.0.0.1:1/${JUDGELINT_ACCOUNT}" }
      status, _out, err = judgelint("app/bad.rb", model: model, env: { "JUDGELINT_ACCOUNT" => "account-123" })

      assert_equal 2, status
      assert_includes err, "${JUDGELINT_ACCOUNT}"
      refute_includes err, "account-123"
    end
  end

  def test_plain_http_goes_only_to_this_machine
    in_smelly_project do
      status, _out, err = judgelint("app/bad.rb", model: { "api_base" => "http://judge.example.invalid" })

      assert_equal 2, status
      assert_match(/isn't https/, err)
    end
  end

  def test_a_preset_pointed_elsewhere_doesnt_get_its_key
    in_smelly_project do
      model = { "api_key_env" => nil }
      judgelint("app/bad.rb", model: model, env: { "TYPESAFE_API_KEY" => "typesafe-key" })

      assert_equal [nil], @server.requests.map { |r| r[:authorization] }
    end
  end
end
