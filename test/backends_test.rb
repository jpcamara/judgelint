# frozen_string_literal: true

require "test_helper"

class BackendsTest < Minitest::Test
  include ProjectHelpers

  def setup
    @server = StubSystemOne.new
    ENV["JUDGELINT_TEST_KEY"] = "secret"
  end

  def teardown
    @server.stop
    ENV.delete("JUDGELINT_TEST_KEY")
  end

  def test_system_one_sends_the_protocol_body
    rules = [rule("smell", yes_means: "It smells.", no_means: "It doesn't."), rule("plain")]
    answers = Judgelint::Backends::SystemOne.new(stub_config).judge("SMELL", rules)

    assert_equal({ "smell" => 0.9, "plain" => 0.9 }, answers)
    request = @server.requests.first
    assert_equal "/v1/systemone", request[:path]
    assert_equal "Bearer secret", request[:authorization]
    assert_equal(
      {
        "model" => "jev-latest", "state" => "SMELL",
        "questions" => {
          "smell" => { "type" => "noul", "instructions" => "Does this code smell?",
                       "criteria" => { "true" => "It smells.", "false" => "It doesn't." } },
          "plain" => { "type" => "noul", "instructions" => "Does this code smell?" }
        }
      },
      request[:payload]
    )
  end

  def test_ruby_llm_sends_the_same_body
    rules = [rule("smell", yes_means: "It smells.", no_means: "It doesn't."), rule("plain")]
    answers = Judgelint::Backends::RubyLLM.new(stub_config(backend: "ruby_llm")).judge("fine", rules)

    assert_equal({ "smell" => 0.1, "plain" => 0.1 }, answers)
    request = @server.requests.first
    assert_equal "/v1/systemone", request[:path]
    assert_equal "Bearer secret", request[:authorization]
    direct = Judgelint::Backends::SystemOne.payload("jev-latest", "fine", rules, {})
    assert_equal direct, request[:payload]
  end

  def test_provider_options_join_the_body
    config = stub_config(provider_options: { "x_celeris" => { "explain" => true } })
    Judgelint::Backends::SystemOne.new(config).judge("x", [rule])

    assert_equal({ "explain" => true }, @server.requests.first[:payload]["x_celeris"])
  end

  def test_errors_name_the_status_and_detail
    server = StubSystemOne.new(status: 401, body: '{"detail":"bad key"}')
    error = assert_raises(Judgelint::BackendError) do
      Judgelint::Backends::SystemOne.new(stub_config(api_base: server.base)).judge("x", [rule])
    end
    assert_match(/401: bad key/, error.message)
  ensure
    server&.stop
  end

  def test_missing_answers_are_errors
    server = StubSystemOne.new(body: '{"answers":{}}')
    error = assert_raises(Judgelint::BackendError) do
      Judgelint::Backends::SystemOne.new(stub_config(api_base: server.base)).judge("x", [rule])
    end
    assert_match(/No yes\/no answer for smell/, error.message)
  ensure
    server&.stop
  end

  def test_unreachable_endpoint_is_a_backend_error
    config = stub_config(api_base: "http://127.0.0.1:1")
    assert_raises(Judgelint::BackendError) { Judgelint::Backends::SystemOne.new(config).judge("x", [rule]) }
  end

  private

  def stub_config(**overrides)
    config(api_base: @server.base, api_key_env: "JUDGELINT_TEST_KEY", **overrides)
  end
end
