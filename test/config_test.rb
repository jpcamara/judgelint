# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  include ProjectHelpers

  def test_defaults_to_jev_on_typesafe
    in_project do
      config = Judgelint::Config.load

      assert_equal "typesafe", config.provider
      assert_equal "jev-latest", config.model
      assert_equal "https://api.typesafe.ai", config.api_base
      assert_equal "TYPESAFE_API_KEY", config.api_key_env
      assert_in_delta 0.7, config.threshold
      assert_equal ".judgelint/cache.json", config.cache_path
    end
  end

  def test_provider_presets_and_overrides
    in_project do
      write(".judgelint.yml", "provider: celeris\nthreshold: 0.6\ncache: false\n")
      config = Judgelint::Config.load(overrides: { "model" => "other" })

      assert_equal "https://inference.celeris.ai/celeris-1-decision", config.api_base
      assert_equal "CELERIS_API_KEY", config.api_key_env
      assert_equal "other", config.model
      assert_in_delta 0.6, config.threshold
      assert_nil config.cache_path
    end
  end

  def test_switching_provider_drops_the_files_provider_settings
    in_project do
      write(".judgelint.yml", "provider: typesafe\nmodel: jev-preview\nthreshold: 0.6\n")

      switched = Judgelint::Config.load(overrides: { "provider" => "openai" })
      assert_equal "gpt-6-luna", switched.model
      assert_in_delta 0.6, switched.threshold

      same = Judgelint::Config.load(overrides: { "provider" => "typesafe" })
      assert_equal "jev-preview", same.model

      chosen = Judgelint::Config.load(overrides: { "provider" => "openai", "model" => "gpt-6-luna-mini" })
      assert_equal "gpt-6-luna-mini", chosen.model
    end
  end

  def test_rejects_unknown_keys_and_bad_values
    in_project do
      write(".judgelint.yml", "modle: jev\n")
      assert_raises(Judgelint::ConfigError) { Judgelint::Config.load }

      write(".judgelint.yml", "threshold: 0.3\nwarn_at: 0.5\n")
      assert_raises(Judgelint::ConfigError) { Judgelint::Config.load }
    end
  end

  def test_presets_fill_protocol_path_auth_and_batch_size
    openai = config(provider: "openai")
    assert_equal ["decisions", "/v1/decisions", "bearer"], [openai.protocol, openai.path, openai.auth]

    cloudflare = config(provider: "cloudflare")
    assert_equal "/@cf/cloudflare/{model}", cloudflare.path
    assert_equal 64, cloudflare.batch_size

    databricks = config(provider: "databricks", batch_size: 8)
    assert_equal ["system_one", "basic", 8], [databricks.protocol, databricks.auth, databricks.batch_size]
  end

  def test_numbers_in_exponent_form
    assert_in_delta 1.0e-07, config(max_cost_usd: 0.0000001).max_cost_usd
  end

  def test_variables_are_left_for_the_client_to_expand
    assert_includes config(provider: "cloudflare").api_base, "${CLOUDFLARE_ACCOUNT_ID}"
  end
end
