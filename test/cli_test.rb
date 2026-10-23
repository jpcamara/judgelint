# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# Runs the command line in-process, through exe/judgelint, and, when
# JUDGELINT_BINARY points at a Spinel build (`rake test:spinel`), through the
# native binary. All three must agree.
class CLITest < Minitest::Test
  include ProjectHelpers

  ROOT = File.expand_path("..", __dir__)

  def setup
    @server = StubSystemOne.new
  end

  def teardown
    @server.stop
  end

  def test_check_reports_violations_and_exits_one
    in_smelly_project do
      runners.each do |name, run|
        status, out, = run.call(["check"])

        assert_equal 1, status, name
        assert_match(%r{^app/bad\.rb\n  x error\s+smell\s+0\.90  Smelly code is hard to change\.$}, out, name)
        refute_match(/good\.rb/, out, name)
        assert_match(/^2 files, 1 violations$/, out, name)
      end
    end
  end

  def test_check_json_output
    in_smelly_project do
      runners.each do |name, run|
        _status, out, = run.call(["check", "--format", "json", "app/bad.rb"])
        data = JSON.parse(out)

        assert_equal({ "violation" => 1, "uncertain" => 0, "pass" => 0, "skipped" => 0, "refused" => 0 },
                     data["summary"], name)
        assert_equal "smell", data["results"].first["rule"], name
        assert_in_delta 0.9, data["results"].first["probability"], 0.001, name
      end
    end
  end

  def test_clean_files_exit_zero
    in_smelly_project do
      runners.each do |name, run|
        status, out, = run.call(["app/good.rb"])

        assert_equal 0, status, name
        assert_equal "1 file, 0 violations\n", out, name
      end
    end
  end

  def test_test_command_scores_examples
    in_smelly_project do
      write(".judgelint/rules/smell/fail/bad.rb", "SMELL")
      write(".judgelint/rules/smell/pass/good.rb", "fine")
      write(".judgelint/rules/smell/pass/wrong.rb", "SMELL")

      runners.each do |name, run|
        status, out, = run.call(["test"])

        assert_equal 1, status, name
        assert_match(/^smell  2\/3$/, out, name)
        assert_match(/MISS pass 0\.90/, out, name)
        assert_match(/^2\/3 examples judged correctly$/, out, name)
      end
    end
  end

  def test_usage_and_config_errors_exit_two
    in_smelly_project do
      runners.each do |name, run|
        status, _out, err = run.call(["--frobnicate"])
        assert_equal 2, status, name
        assert_match(/unknown option --frobnicate/, err, name)

        status, _out, err = run.call(["missing.rb"])
        assert_equal 2, status, name
        assert_match(/No such file: missing\.rb/, err, name)
      end
    end
  end

  def test_api_errors_exit_two
    in_smelly_project do
      runners.each do |name, run|
        status, _out, err = run.call(["--model", "x", "app/bad.rb"], api_base: "http://127.0.0.1:1")
        assert_equal 2, status, name
        assert_match(/judgelint: /, err, name)
      end
    end
  end

  def test_openai_decisions_protocol
    in_smelly_project do
      runners.each do |name, run|
        status, out, = run.call(["app/bad.rb"], settings: "provider: openai")

        assert_equal 1, status, name
        assert_match(/1 violations/, out, name)
      end
      assert(@server.requests.all? { |request| request[:path] == "/v1/decisions" })
    end
  end

  def test_cloudflare_envelope_and_account_in_the_url
    wrapped = { "result" => { "answers" => { "smell" => { "type" => "noul", "noul" => 0.95 } } }, "success" => true }
    server = StubSystemOne.new(body: wrapped)
    in_smelly_project do
      runners.each do |name, run|
        ENV["JUDGELINT_TEST_ACCOUNT"] = "acct"
        settings = "provider: cloudflare\napi_base: #{server.base}/accounts/${JUDGELINT_TEST_ACCOUNT}/ai/run"
        status, out, = run.call(["app/good.rb"], settings: settings)

        assert_equal 1, status, name
        assert_match(/0\.95/, out, name)
      end
    end
    assert(server.requests.all? { |request| request[:path] == "/accounts/acct/ai/run/@cf/cloudflare/clef" })
  ensure
    ENV.delete("JUDGELINT_TEST_ACCOUNT")
    server&.stop
  end

  def test_basic_auth_and_extra_headers
    in_smelly_project do
      runners.each do |name, run|
        status, = run.call(["app/good.rb"], settings: "auth: basic\nheaders: { X-Judgelint: yes-please }")
        assert_equal 0, status, name
      end
    end
    request = @server.requests.last
    assert_equal "Basic #{['token:secret'].pack('m0')}", request[:authorization]
    assert_equal "yes-please", request[:headers]["x-judgelint"]
  end

  def test_retries_then_succeeds
    ok = { "answers" => { "smell" => { "type" => "noul", "noul" => 0.1 } } }
    in_smelly_project do
      runners.each do |name, run|
        server = StubSystemOne.new(responses: [[429, { "detail" => "slow" }, { "Retry-After" => "0" }], [200, ok]])
        status, out, = run.call(["app/good.rb"], api_base: server.base)

        assert_equal 0, status, name
        assert_equal "1 file, 0 violations\n", out, name
        assert_equal 2, server.requests.size, name
      ensure
        server&.stop
      end
    end
  end

  def test_providers_lists_the_presets
    in_project do
      runners.each do |name, run|
        status, out, = run.call(["providers"])

        assert_equal 0, status, name
        assert_match(/^cloudflare\s+clef\s+CLOUDFLARE_API_TOKEN/, out, name)
        assert_match(/^openai\s+gpt-6-luna/, out, name)
      end
    end
  end

  def test_init_writes_a_working_example
    in_project do
      runners.each do |name, run|
        status, out, = run.call(["init"])
        assert_equal 0, status, name
        assert_match(/no-silent-rescue\.md/, out, name)
      end
      rules = Judgelint::Rule.load_dir(".judgelint/rules", default_threshold: 0.7)
      assert_equal ["no-silent-rescue"], rules.map(&:id)
    end
  end

  def test_version_and_help
    in_project do
      runners.each do |name, run|
        _status, out, = run.call(["--version"])
        assert_equal "judgelint #{Judgelint::VERSION}\n", out, name

        _status, out, = run.call(["--help"])
        assert_match(/Usage: judgelint/, out, name)
      end
    end
  end

  def test_a_missing_api_key_is_a_config_error
    in_smelly_project do
      write(".judgelint.yml", "api_base: #{@server.base}\napi_key_env: JUDGELINT_UNSET_KEY\n")
      out = StringIO.new
      err = StringIO.new

      assert_equal 2, Judgelint::CLI.new(["app/bad.rb"], out: out, err: err).run
      assert_match(/Set JUDGELINT_UNSET_KEY/, err.string)
      assert_empty @server.requests
    end
  end

  private

  def in_smelly_project(&)
    in_project do |dir|
      write_rule("smell")
      write("app/bad.rb", "SMELL\n")
      write("app/good.rb", "fine\n")
      write("lib/ignored.rb", "SMELL\n")
      yield dir
    end
  end

  def runners
    runners = {
      "in-process" => method(:run_in_process),
      "exe" => ->(args, **opts) { run_command(["ruby", "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe/judgelint")], args, **opts) }
    }
    binary = ENV.fetch("JUDGELINT_BINARY", nil)
    runners["spinel"] = ->(args, **opts) { run_command([binary], args, **opts) } if binary
    runners
  end

  # Always called inside a temporary project. +settings+ is more YAML, and
  # its keys win over the defaults here.
  def env(api_base, settings)
    defaults = { "api_base" => api_base, "api_key_env" => "JUDGELINT_TEST_KEY", "cache" => "false" }
    lines = settings.lines.map(&:chomp).reject(&:empty?)
    given = lines.map { |line| line.split(":", 2).first }
    defaults.each { |key, value| lines << "#{key}: #{value}" unless given.include?(key) }
    write(".judgelint.yml", "#{lines.join("\n")}\n")
    { "JUDGELINT_TEST_KEY" => "secret" }
  end

  def run_in_process(args, api_base: @server.base, settings: "")
    ENV.update(env(api_base, settings))
    out = StringIO.new
    err = StringIO.new
    status = Judgelint::CLI.new(args, out: out, err: err).run
    [status, out.string, err.string]
  ensure
    ENV.delete("JUDGELINT_TEST_KEY")
  end

  def run_command(command, args, api_base: @server.base, settings: "")
    out, err, status = Open3.capture3(env(api_base, settings), *command, *args)
    [status.exitstatus, out, err]
  end
end
