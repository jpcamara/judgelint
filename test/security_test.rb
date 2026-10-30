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

  def test_pr_checks_against_the_base_branchs_config_rules_and_cache
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
      refute_includes @server.requests.first[:payload].to_s, "Context", "nor its rules"
      assert_equal "jlcache1", File.read(".judgelint/cache.bin"), "and the checkout's cache is left alone"
    end
  ensure
    attacker&.stop
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

  def test_pr_leaves_the_checkouts_cache_alone
    Dir.mktmpdir("judgelint-outside") do |outside|
      File.write(File.join(outside, "cache.bin"), "keep me")
      in_smelly_project do |dir|
        write_config
        git_repo
        git("init", "--bare", "-q", "#{dir}/origin.git")
        git("remote", "add", "origin", "#{dir}/origin.git")
        git("push", "-q", "origin", "main")
        FileUtils.rm_rf(".judgelint")
        File.symlink(outside, ".judgelint")
        _out, err, status = Open3.capture3({ "GITHUB_BASE_REF" => "main" }, BINARY, "--pr")

        assert_equal 0, status.exitstatus, err
        assert_equal "keep me", File.read(File.join(outside, "cache.bin"))
      end
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

  def test_a_new_violation_next_to_an_old_one_still_fails
    in_project do
      write("CONVENTIONS.md", "- **No smells.**\n")
      write("app/a.rb", "SMELL\n#{"fine\n" * 9}")
      git_repo
      lines = File.readlines("app/a.rb")
      lines[5] = "SMELL again\n"
      File.write("app/a.rb", lines.join)
      status, out, = judgelint("--base", "main")

      assert_equal 1, status
      assert_match(/1 violations/, out)
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

  def test_a_retry_after_that_isnt_a_number_is_ignored
    @server.stop
    @server = StubSystemOne.new(responses: [[429, "{}", { "Retry-After" => "NaN" }], [200, nil]])
    in_smelly_project do
      status, _out, err = judgelint("app/bad.rb")

      assert_equal 1, status, err
      assert_equal 2, @server.requests.size
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
