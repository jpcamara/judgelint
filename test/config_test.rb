# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  include ProjectHelpers

  def test_defaults_to_jev_on_typesafe
    in_project do
      config = Judgelint::ConfigLoader.load

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
      config = Judgelint::ConfigLoader.load(overrides: { "model" => "other" })

      assert_equal "https://inference.celeris.ai/celeris-1-decision", config.api_base
      assert_equal "CELERIS_API_KEY", config.api_key_env
      assert_equal "other", config.model
      assert_in_delta 0.6, config.threshold
      assert_nil config.cache_path
    end
  end

  def test_rejects_unknown_keys_and_bad_values
    in_project do
      write(".judgelint.yml", "modle: jev\n")
      assert_raises(Judgelint::ConfigError) { Judgelint::ConfigLoader.load }

      write(".judgelint.yml", "threshold: 0.3\nwarn_at: 0.5\n")
      assert_raises(Judgelint::ConfigError) { Judgelint::ConfigLoader.load }
    end
  end

  def test_unknown_provider_needs_a_model
    error = assert_raises(Judgelint::ConfigError) { config(provider: "acme") }
    assert_match(/model is required/, error.message)
  end
end
