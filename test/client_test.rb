# frozen_string_literal: true

require "test_helper"

# What judgelint sends a model's endpoint, and what it does when the
# endpoint fails.
class ClientTest < Minitest::Test
  include ProjectHelpers

  OK = { "answers" => { "smell.1-1" => { "type" => "noul", "noul" => 0.4 } } }.freeze

  def teardown
    @server&.stop
  end

  def test_sends_system_one_with_a_bearer_key
    @server = StubSystemOne.new
    in_smelly_project do
      judgelint("app/bad.rb")

      request = @server.requests.first
      assert_equal ["/v1/systemone", "Bearer secret"], request.values_at(:path, :authorization)
      assert_equal %w[model questions state], request[:payload].keys.sort
      assert_equal "jev-latest", request[:payload]["model"]
    end
  end

  def test_auth_styles
    @server = StubSystemOne.new
    in_smelly_project do
      judgelint("app/good.rb", model: { "auth" => "header:api-key" })
      assert_equal "secret", @server.requests.last[:headers]["api-key"]
      assert_nil @server.requests.last[:authorization]

      judgelint("app/good.rb", model: { "auth" => "none" })
      assert_nil @server.requests.last[:authorization]
    end
  end

  def test_local_servers_need_no_key_and_llamacpp_needs_no_model
    @server = StubSystemOne.new
    in_smelly_project do
      status, = judgelint("app/good.rb", model: { "provider" => "llamacpp", "api_key_env" => nil })

      assert_equal 0, status
      assert_nil @server.requests.first[:authorization]
      refute @server.requests.first[:payload].key?("model")
    end
  end

  def test_extra_headers_and_provider_options
    @server = StubSystemOne.new
    in_smelly_project do
      model = { "headers" => { "TypeSafe-Danger-Zone-Long-Context" => "${JUDGELINT_TEST_HEADER}" },
                "provider_options" => { "x_celeris" => { "explain" => true } } }
      judgelint("app/good.rb", model: model, env: { "JUDGELINT_TEST_HEADER" => "true" })

      request = @server.requests.first
      assert_equal "true", request[:headers]["typesafe-danger-zone-long-context"]
      assert_equal({ "explain" => true }, request[:payload]["x_celeris"])
    end
  end

  def test_retries_rate_limits_and_server_errors
    @server = StubSystemOne.new(responses: [[429, { "detail" => "slow down" }, { "Retry-After" => "1" }],
                                            [529, { "detail" => "overloaded" }], [200, OK]])
    in_smelly_project do
      (status,), elapsed = timed { judgelint("app/good.rb") }

      assert_equal [0, 3], [status, @server.requests.size]
      assert_operator elapsed, :>=, 2.0, "a second for Retry-After, then a second's backoff"
    end
  end

  def test_gives_up_after_the_retries
    @server = StubSystemOne.new(status: 503, body: '{"detail":"down"}')
    in_smelly_project do
      status, _out, err = judgelint("app/good.rb")

      assert_equal 2, status
      assert_match(/typesafe:jev-latest answered 503: down/, err)
      assert_equal 4, @server.requests.size, "the first try and three retries"
    end
  end

  def test_client_errors_are_not_retried
    @server = StubSystemOne.new(status: 401, body: '{"detail":"bad key"}')
    in_smelly_project do
      status, _out, err = judgelint("app/good.rb")

      assert_equal 2, status
      assert_match(/401: bad key/, err)
      assert_equal 1, @server.requests.size
    end
  end

  def test_retries_a_dropped_connection_after_a_backoff
    @server = StubSystemOne.new(hang_up: 1, responses: [[200, OK]])
    in_smelly_project do
      (status,), elapsed = timed { judgelint("app/good.rb") }

      assert_equal [0, 1], [status, @server.requests.size]
      assert_operator elapsed, :>=, 2.0
    end
  end

  def test_a_refused_connection_fails_at_once
    @server = StubSystemOne.new
    in_smelly_project do
      (status, _out, err), elapsed = timed { judgelint("app/good.rb", model: { "api_base" => "http://127.0.0.1:1" }) }

      assert_equal 2, status
      assert_match(/Couldn't reach typesafe:jev-latest/, err)
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_an_unset_variable_in_the_url_is_a_config_error
    @server = StubSystemOne.new
    in_smelly_project do
      status, _out, err = judgelint("app/good.rb", model: { "provider" => "cloudflare", "api_base" => nil },
                                                   env: { "CLOUDFLARE_ACCOUNT_ID" => nil })

      assert_equal 2, status
      assert_match(/Set CLOUDFLARE_ACCOUNT_ID/, err)
    end
  end

  private

  # The block's result, and how many seconds it took.
  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end
end
