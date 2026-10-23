# frozen_string_literal: true

module Judgelint
  # Presets for the services and servers that answer System One questions.
  # Any key can be overridden in .judgelint.yml, and a provider not listed here
  # works by setting api_base (and model, path, protocol, auth as needed).
  #
  # protocol is "system_one" (POST {model, state, questions} keyed by name) or
  # "decisions" (OpenAI's Decisions API: input, questions as a list). The path
  # doesn't decide it: Perplexity and Hanzo take System One at /v1/decisions.
  #
  # auth is "bearer", "basic" (user "token", for Databricks), "none", or
  # "header:<name>" (Microsoft Foundry's api-key). A preset with no
  # api_key_env sends no credentials unless you set one.
  #
  # ${VAR} in api_base or path reads the environment; {model} in path is the
  # model id. batch_size is the provider's most questions per request. needs
  # says what a preset can't fill in for you.
  PROVIDERS = {
    "typesafe" => {
      "api_base" => "https://api.typesafe.ai", "api_key_env" => "TYPESAFE_API_KEY", "model" => "jev-latest"
    },
    "openrouter" => {
      "api_base" => "https://openrouter.ai/api", "api_key_env" => "OPENROUTER_API_KEY", "model" => "typesafe/jev-1.13"
    },
    "celeris" => {
      "api_base" => "https://inference.celeris.ai/celeris-1-decision", "api_key_env" => "CELERIS_API_KEY",
      "model" => "celeris-1-decision"
    },
    "cloudflare" => {
      "api_base" => "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/run",
      "path" => "/@cf/cloudflare/{model}", "api_key_env" => "CLOUDFLARE_API_TOKEN", "model" => "clef",
      "batch_size" => "64"
    },
    "openai" => {
      "api_base" => "https://api.openai.com", "path" => "/v1/decisions", "protocol" => "decisions",
      "api_key_env" => "OPENAI_API_KEY", "model" => "gpt-6-luna"
    },
    "perplexity" => {
      "api_base" => "https://api.perplexity.ai", "path" => "/v1/decisions", "api_key_env" => "PERPLEXITY_API_KEY",
      "model" => "pplx-decider-latest", "batch_size" => "128"
    },
    "vercel" => {
      "api_base" => "https://ai-gateway.vercel.sh/typesafe", "api_key_env" => "AI_GATEWAY_API_KEY",
      "model" => "typesafe-ai/jev"
    },
    "digitalocean" => {
      "api_base" => "https://inference.do-ai.run", "api_key_env" => "MODEL_ACCESS_KEY", "model" => "typesafe-jev-1.13.0"
    },
    "upstage" => {
      "api_base" => "https://api.upstage.ai", "api_key_env" => "UPSTAGE_API_KEY", "model" => "solar-decide"
    },
    "hanzo" => {
      "api_base" => "https://api.hanzo.ai", "path" => "/v1/decisions", "api_key_env" => "HANZO_API_KEY",
      "model" => "kai", "batch_size" => "100"
    },
    "foundry" => {
      "path" => "/providers/microsoft/v1/systemone", "auth" => "header:api-key", "api_key_env" => "AZURE_API_KEY",
      "needs" => "api_base (your Foundry resource endpoint) and model (your deployment name)"
    },
    "databricks" => {
      "path" => "/ai-gateway/typesafe/v1/systemone", "auth" => "basic", "api_key_env" => "DATABRICKS_TOKEN",
      "needs" => "api_base (https://<workspace host>) and model (a Unity Catalog name)"
    },
    "ollama" => {
      "api_base" => "http://localhost:11434", "batch_size" => "64", "needs" => "model (a decision model you've pulled)"
    },
    "llamacpp" => { "api_base" => "http://localhost:8080" },
    "vllm" => { "api_base" => "http://localhost:8000", "batch_size" => "64", "needs" => "model (the model the server runs)" },
    "litellm" => {
      "api_base" => "http://localhost:4000", "api_key_env" => "LITELLM_API_KEY",
      "needs" => "model (a decision model routed by your proxy)"
    }
  }.freeze
end
