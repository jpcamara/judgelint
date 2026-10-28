//! Presets for the services and servers that answer System One questions,
//! read from providers.yml. Any key can be overridden in .judgelint.yml, and a
//! provider not listed works by setting api_base (and model, path, protocol,
//! auth as needed).
//!
//! protocol is system_one (POST {model, state, questions} keyed by name) or
//! decisions (OpenAI's Decisions API: input, questions as a list). The path
//! doesn't decide it: Perplexity and Hanzo take System One at /v1/decisions.
//!
//! auth is bearer, basic (user "token", for Databricks), none, or
//! header:<name> (Microsoft Foundry's api-key). A preset with no api_key_env
//! sends no credentials unless you set one.
//!
//! ${VAR} in api_base or path reads the environment; {model} in path is the
//! model id. batch_size is the provider's most questions per request. prices
//! are USD per million input tokens, by model (OpenRouter reports each
//! request's cost instead). needs says what a preset can't fill in.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::Deserialize;

use crate::protocol::Protocol;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preset {
    pub name: String,
    pub api_base: Option<String>,
    pub api_key_env: Option<String>,
    pub model: Option<String>,
    pub path: Option<String>,
    pub protocol: Option<Protocol>,
    pub auth: Option<String>,
    pub batch_size: Option<usize>,
    pub needs: Option<String>,
    #[serde(default)]
    pub prices: BTreeMap<String, f64>,
}

pub fn all() -> &'static [Preset] {
    static PRESETS: LazyLock<Vec<Preset>> =
        LazyLock::new(|| serde_saphyr::from_str(include_str!("providers.yml")).expect("providers.yml is valid"));
    &PRESETS
}

pub fn find(name: &str) -> Option<&'static Preset> {
    all().iter().find(|p| p.name == name)
}
