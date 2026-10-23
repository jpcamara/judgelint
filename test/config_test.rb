# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  include ProjectHelpers

  def test_defaults_to_jev_on_typesafe
    in_project do
      config = Judgelint::Config.load
      jev = config.models.first

      assert_equal ["typesafe:jev-latest"], config.models.map(&:label)
      assert_equal "https://api.typesafe.ai", jev.api_base
      assert_equal "TYPESAFE_API_KEY", jev.api_key_env
      assert_in_delta 0.042, jev.price_per_million
      assert_in_delta 0.7, config.threshold
      assert_in_delta 0.4, config.warn_at
      assert_in_delta 1.0, config.max_cost_usd
    end
  end

  def test_models_as_provider_and_model
    in_project do
      write(".judgelint.yml", "models: [typesafe, \"cloudflare:clef\", \"openrouter:jaredpalmer/kev-4b\"]\nthreshold: 0.6\n")
      config = Judgelint::Config.load

      assert_equal %w[typesafe:jev-latest cloudflare:clef openrouter:jaredpalmer/kev-4b], config.models.map(&:label)
      assert_in_delta 0.6, config.threshold
      assert_in_delta 0.3, config.warn_at
    end
  end

  def test_model_on_the_command_line_replaces_the_files
    in_project do
      write(".judgelint.yml", "models: [typesafe, cloudflare]\nthreshold: 0.6\n")
      config = Judgelint::Config.load(overrides: { "models" => "openai" })

      assert_equal ["openai:gpt-6-luna"], config.models.map(&:label)
      assert_in_delta 0.6, config.threshold
    end
  end

  def test_a_custom_endpoint
    custom = config(models: [{ "api_base" => "https://gateway.example.com", "model" => "decider", "auth" => "none",
                               "protocol" => "decisions", "price_per_million" => 0.5, "batch_size" => 8 }]).models.first

    assert_equal "custom:decider", custom.label
    assert_equal ["decisions", "none", 8], [custom.protocol, custom.auth, custom.batch_size]
    assert_in_delta 0.5, custom.price_per_million
  end

  def test_presets_fill_protocol_path_auth_and_limits
    openai = endpoint(provider: "openai")
    assert_equal ["decisions", "/v1/decisions", "bearer"], [openai.protocol, openai.path, openai.auth]

    cloudflare = endpoint(provider: "cloudflare")
    assert_equal "/@cf/cloudflare/{model}", cloudflare.path
    assert_equal 64, cloudflare.batch_size
    assert_includes cloudflare.api_base, "${CLOUDFLARE_ACCOUNT_ID}", "the client expands variables when it sends"

    assert_nil endpoint(provider: "typesafe", model: "some-new-jev").price_per_million, "no price for an unknown model"
  end

  def test_rejects_unknown_keys_and_bad_values
    in_project do
      ["provider: typesafe\n", "threshold: high\n", "threshold: 2\n", "models: []\n", "models: [{modle: x}]\n"].each do |yaml|
        write(".judgelint.yml", yaml)
        assert_raises(Judgelint::ConfigError, yaml) { Judgelint::Config.load }
      end
    end
  end

  def test_numbers_in_exponent_form
    assert_in_delta 1.0e-07, config(max_cost_usd: 0.0000001).max_cost_usd
  end
end
