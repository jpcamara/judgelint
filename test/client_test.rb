# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include ProjectHelpers

  def setup
    @server = StubSystemOne.new
    ENV["JUDGELINT_TEST_KEY"] = "secret"
  end

  def teardown
    @server.stop
    ENV.delete("JUDGELINT_TEST_KEY")
  end

  def test_sends_the_system_one_body
    rules = [rule("smell", yes_means: "It smells.", no_means: "It doesn't."), rule("plain")]
    answers = Judgelint::Client.new(stub_config).judge("SMELL", rules)

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

  def test_provider_options_join_the_body
    config = stub_config(provider_options: { "x_celeris" => { "explain" => true } })
    Judgelint::Client.new(config).judge("x", [rule])

    assert_equal({ "explain" => true }, @server.requests.first[:payload]["x_celeris"])
  end

  def test_errors_name_the_status_and_detail
    server = StubSystemOne.new(status: 401, body: '{"detail":"bad key"}')
    error = assert_raises(Judgelint::ApiError) do
      Judgelint::Client.new(stub_config(api_base: server.base)).judge("x", [rule])
    end
    assert_match(/401: bad key/, error.message)
  ensure
    server&.stop
  end

  def test_missing_answers_are_errors
    server = StubSystemOne.new(body: '{"answers":{}}')
    error = assert_raises(Judgelint::ApiError) do
      Judgelint::Client.new(stub_config(api_base: server.base)).judge("x", [rule])
    end
    assert_match(/No yes\/no answer for smell/, error.message)
  ensure
    server&.stop
  end

  def test_unreachable_endpoint_is_an_api_error
    config = stub_config(api_base: "http://127.0.0.1:1")
    assert_raises(Judgelint::ApiError) { Judgelint::Client.new(config).judge("x", [rule]) }
  end

  def test_a_missing_api_key_fails_before_any_request
    error = assert_raises(Judgelint::ConfigError) do
      Judgelint::Client.new(stub_config(api_key_env: "JUDGELINT_UNSET_KEY"))
    end
    assert_match(/Set JUDGELINT_UNSET_KEY/, error.message)
  end

  def test_an_unknown_provider_needs_an_api_base
    error = assert_raises(Judgelint::ConfigError) { Judgelint::Client.new(config(provider: "acme", model: "m")) }
    assert_match(/Set api_base for provider acme/, error.message)
  end

  private

  def stub_config(**overrides)
    config(api_base: @server.base, api_key_env: "JUDGELINT_TEST_KEY", **overrides)
  end
end
