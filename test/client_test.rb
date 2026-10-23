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
    smell = question("smell", yes_means: "It smells.", no_means: "It doesn't.")
    plain = question("plain", first: 41, last: 80)
    answers = client.judge("SMELL", [smell, plain])

    assert_equal({ "smell.1-40" => 0.9, "plain.41-80" => 0.9 }, answers)
    request = @server.requests.first
    assert_equal "/v1/systemone", request[:path]
    assert_equal "Bearer secret", request[:authorization]
    assert_equal(
      {
        "model" => "jev-latest", "state" => "SMELL",
        "questions" => {
          "smell.1-40" => { "type" => "noul", "instructions" => smell.instructions,
                            "criteria" => { "true" => "It smells.", "false" => "It doesn't." } },
          "plain.41-80" => { "type" => "noul", "instructions" => plain.instructions }
        }
      },
      request[:payload]
    )
  end

  def test_sends_the_decisions_body
    smell = question("smell", yes_means: "It smells.", no_means: "It doesn't.")
    plain = question("plain")
    answers = client(provider: "openai").judge("fine", [smell, plain])

    assert_equal({ "smell.1-40" => 0.1, "plain.1-40" => 0.1 }, answers)
    request = @server.requests.first
    assert_equal "/v1/decisions", request[:path]
    assert_equal(
      {
        "model" => "gpt-6-luna", "input" => "fine",
        "questions" => [
          { "type" => "predicate", "name" => "smell.1-40",
            "instructions" => "#{smell.instructions}\nYes: It smells.\nNo: It doesn't." },
          { "type" => "predicate", "name" => "plain.1-40", "instructions" => plain.instructions }
        ]
      },
      request[:payload]
    )
  end

  def test_system_one_bodies_at_a_decisions_path
    client(provider: "perplexity").judge("x", [question])

    request = @server.requests.first
    assert_equal "/v1/decisions", request[:path]
    assert request[:payload].key?("state")
  end

  def test_decisions_answers_match_by_name_then_by_order
    data = { "answers" => [{ "type" => "predicate", "name" => "b.1-40", "probability" => 0.2 },
                           { "type" => "predicate", "probability" => 0.7 }] }
    parsed = Judgelint::Protocol::Decisions.parse(data, [question("a"), question("b")])

    assert_equal({ "a.1-40" => 0.7, "b.1-40" => 0.2 }, parsed)
  end

  def test_refusals_are_nil_not_errors
    data = { "answers" => [{ "type" => "refusal", "name" => "a.1-40" }] }
    assert_equal({ "a.1-40" => nil }, Judgelint::Protocol::Decisions.parse(data, [question("a")]))

    data = { "answers" => { "a.1-40" => { "type" => "refusal" } } }
    assert_equal({ "a.1-40" => nil }, Judgelint::Protocol::SystemOne.parse(data, [question("a")]))
  end

  def test_auth_styles
    { "bearer" => ["authorization", "Bearer secret"], "header:api-key" => ["api-key", "secret"] }.each do |auth, (header, value)|
      server = StubSystemOne.new
      client(api_base: server.base, auth: auth).judge("x", [question])
      assert_equal value, server.requests.first[:headers][header], auth
    ensure
      server&.stop
    end

    client(auth: "none").judge("x", [question])
    assert_nil @server.requests.last[:authorization]
  end

  def test_local_servers_need_no_key_and_llamacpp_needs_no_model
    Judgelint::Client.new(config(provider: "llamacpp", api_base: @server.base)).judge("x", [question])

    request = @server.requests.first
    assert_nil request[:authorization]
    refute request[:payload].key?("model")
  end

  def test_extra_headers_and_provider_options
    with_env("JUDGELINT_TEST_HEADER" => "true") do
      client(headers: { "TypeSafe-Danger-Zone-Long-Context" => "${JUDGELINT_TEST_HEADER}" },
             provider_options: { "x_celeris" => { "explain" => true } }).judge("x", [question])
    end

    request = @server.requests.first
    assert_equal "true", request[:headers]["typesafe-danger-zone-long-context"]
    assert_equal({ "explain" => true }, request[:payload]["x_celeris"])
  end

  def test_retries_rate_limits_and_server_errors
    ok = { "answers" => { "smell.1-40" => { "type" => "noul", "noul" => 0.4 } } }
    server = StubSystemOne.new(responses: [[429, { "detail" => "slow down" }, { "Retry-After" => "3" }],
                                           [529, { "detail" => "overloaded" }], [200, ok]])
    sleeps = []
    client = Judgelint::Client.new(stub_config(api_base: server.base), sleeper: ->(seconds) { sleeps << seconds })

    assert_equal({ "smell.1-40" => 0.4 }, client.judge("x", [question]))
    assert_equal [3.0, 1.0], sleeps
  ensure
    server&.stop
  end

  def test_gives_up_after_the_retries
    server = StubSystemOne.new(status: 503, body: '{"detail":"down"}')
    client = Judgelint::Client.new(stub_config(api_base: server.base, retries: 1), sleeper: ->(_) {})

    error = assert_raises(Judgelint::ApiError) { client.judge("x", [question]) }
    assert_match(/typesafe answered 503: down/, error.message)
    assert_equal 2, server.requests.size
  ensure
    server&.stop
  end

  def test_client_errors_are_not_retried
    server = StubSystemOne.new(status: 401, body: '{"detail":"bad key"}')
    error = assert_raises(Judgelint::ApiError) { client(api_base: server.base).judge("x", [question]) }

    assert_match(/401: bad key/, error.message)
    assert_equal 1, server.requests.size
  ensure
    server&.stop
  end

  # Error bodies captured from TypeSafe, Celeris, OpenAI, OpenRouter, and
  # Cloudflare on Oct 23, 2026, plus Vercel's and the local proxies' shapes.
  def test_reads_every_providers_error_shape
    {
      '{"detail":{"error_type":"authentication_error","message":"Cannot authenticate."}}' => "Cannot authenticate.",
      '{"detail":[{"loc":["body","bogus"],"msg":"unknown field","type":"value_error"}]}' => "unknown field",
      '{"detail":"bad key"}' => "bad key",
      '{"error":{"message":"The model `nope` does not exist.","type":"invalid_request_error"}}' =>
        "The model `nope` does not exist.",
      '{"error":{"message":"Model nope/nope does not exist","code":400}}' => "Model nope/nope does not exist",
      '{"errors":[{"message":"AiError: Bad input","code":5006}],"success":false,"result":{}}' => "AiError: Bad input",
      '{"message":"Unauthorized","error_type":"auth"}' => "Unauthorized",
      '{"error":"invalid model"}' => "invalid model",
      "<html>Bad Gateway</html>" => "<html>Bad Gateway</html>"
    }.each do |body, message|
      assert_equal message, Judgelint::Client.error_detail(body), body
    end
  end

  def test_missing_answers_are_errors
    server = StubSystemOne.new(body: '{"answers":{}}')
    error = assert_raises(Judgelint::ApiError) { client(api_base: server.base).judge("x", [question]) }
    assert_match(/No yes\/no answer for smell.1-40/, error.message)
  ensure
    server&.stop
  end

  def test_retries_connection_errors_with_backoff_then_gives_up
    sleeps = []
    client = Judgelint::Client.new(stub_config(api_base: "http://127.0.0.1:1", retries: 3),
                                   sleeper: ->(seconds) { sleeps << seconds })

    error = assert_raises(Judgelint::ApiError) { client.judge("x", [question]) }
    assert_match(/Couldn't reach typesafe/, error.message)
    assert_equal [2.0, 4.0, 8.0], sleeps
  end

  def test_records_usage_and_cost
    server = StubSystemOne.new(body: { "answers" => { "smell.1-40" => { "noul" => 0.2 } },
                                       "usage" => { "input_tokens" => 500_000 } })
    client = client(api_base: server.base)
    2.times { client.judge("x", [question]) }

    assert_equal({ "requests" => 2, "input_tokens" => 1_000_000, "cost_usd" => 0.042 }, client.usage.to_h)
    assert_equal "judgelint: 2 requests, 1,000,000 input tokens, $0.0420", client.usage.line
  ensure
    server&.stop
  end

  def test_prefers_the_cost_a_provider_reports
    server = StubSystemOne.new(body: { "answers" => { "smell.1-40" => { "noul" => 0.2 } },
                                       "usage" => { "input_tokens" => 300, "cost" => 0.0005 } })
    client = client(provider: "openrouter", api_base: server.base)
    client.judge("x", [question])

    assert_in_delta 0.0005, client.usage.cost
  ensure
    server&.stop
  end

  def test_a_missing_api_key_fails_before_any_request
    error = assert_raises(Judgelint::ConfigError) { client(api_key_env: "JUDGELINT_UNSET_KEY") }
    assert_match(/Set JUDGELINT_UNSET_KEY/, error.message)
  end

  def test_says_what_a_preset_still_needs
    with_env("AZURE_API_KEY" => "k") do
      error = assert_raises(Judgelint::ConfigError) { Judgelint::Client.new(config(provider: "foundry", model: "m")) }
      assert_match(/foundry needs api_base \(your Foundry resource endpoint\)/, error.message)
    end

    error = assert_raises(Judgelint::ConfigError) { Judgelint::Client.new(config(provider: "ollama")) }
    assert_match(/ollama needs a model/, error.message)

    error = assert_raises(Judgelint::ConfigError) { Judgelint::Client.new(config(provider: "acme", model: "m")) }
    assert_match(/acme needs api_base/, error.message)
  end

  def test_an_unset_variable_in_the_url_is_a_config_error
    with_env("CLOUDFLARE_ACCOUNT_ID" => nil, "CLOUDFLARE_API_TOKEN" => "k") do
      error = assert_raises(Judgelint::ConfigError) { Judgelint::Client.new(config(provider: "cloudflare")).url }
      assert_match(/Set CLOUDFLARE_ACCOUNT_ID/, error.message)
    end
  end

  # Every preset resolves to the endpoint its provider documents.
  def test_preset_urls
    expected = {
      "typesafe" => "https://api.typesafe.ai/v1/systemone",
      "openrouter" => "https://openrouter.ai/api/v1/systemone",
      "celeris" => "https://inference.celeris.ai/celeris-1-decision/v1/systemone",
      "cloudflare" => "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/cloudflare/clef",
      "openai" => "https://api.openai.com/v1/decisions",
      "perplexity" => "https://api.perplexity.ai/v1/decisions",
      "vercel" => "https://ai-gateway.vercel.sh/typesafe/v1/systemone",
      "digitalocean" => "https://inference.do-ai.run/v1/systemone",
      "upstage" => "https://api.upstage.ai/v1/systemone",
      "hanzo" => "https://api.hanzo.ai/v1/decisions",
      "foundry" => "https://example.services.ai.azure.com/providers/microsoft/v1/systemone",
      "databricks" => "https://example.cloud.databricks.com/ai-gateway/typesafe/v1/systemone",
      "ollama" => "http://localhost:11434/v1/systemone",
      "llamacpp" => "http://localhost:8080/v1/systemone",
      "vllm" => "http://localhost:8000/v1/systemone",
      "litellm" => "http://localhost:4000/v1/systemone"
    }
    assert_equal Judgelint::PROVIDERS.keys.sort, expected.keys.sort

    bases = { "foundry" => "https://example.services.ai.azure.com",
              "databricks" => "https://example.cloud.databricks.com" }
    keys = Judgelint::PROVIDERS.values.filter_map { |preset| preset["api_key_env"] }
    with_env(keys.to_h { |key| [key, "k"] }.merge("CLOUDFLARE_ACCOUNT_ID" => "acct")) do
      expected.each do |provider, url|
        overrides = { provider: provider }
        overrides[:api_base] = bases[provider] if bases[provider]
        overrides[:model] = "m" unless Judgelint::PROVIDERS[provider]["model"]
        assert_equal url, Judgelint::Client.new(config(**overrides)).url, provider
      end
    end
  end

  private

  def stub_config(**overrides)
    config(api_base: @server.base, api_key_env: "JUDGELINT_TEST_KEY", **overrides)
  end

  def client(**overrides)
    Judgelint::Client.new(stub_config(**overrides), sleeper: ->(_seconds) {})
  end

  def question(id = "smell", first: 1, last: 40, **fields)
    Judgelint::Question.new(rule(id, **fields), first, last)
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
