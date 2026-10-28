//! .judgelint.yml, which is optional: which models to ask, the threshold,
//! files to ignore, and a spending limit. Everything else has a fixed value.
//!
//! ```yaml
//! models: [typesafe, cloudflare:clef]   # ask both and average
//! threshold: 0.7
//! ignore: ["vendor/**"]
//! max_cost_usd: 1.00
//! ```

use std::collections::BTreeMap;
use std::sync::LazyLock;

use anyhow::{Context, Result, anyhow, bail};
use regex::Regex;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::glob::Patterns;
use crate::protocol::Protocol;
use crate::providers;

pub const FILE: &str = ".judgelint.yml";
pub const RULES_DIR: &str = ".judgelint/rules";
pub const CACHE: &str = ".judgelint/cache.bin";
pub const WINDOW_LINES: u32 = 40;
/// Files sent at once.
pub const THREADS: usize = 8;
pub const TIMEOUT: u64 = 30;
pub const RETRIES: u32 = 3;
/// Answers this far below the threshold, or less, are uncertain: reported, never failing.
const UNCERTAIN_BAND: f64 = 0.3;

/// A setting that's one value or a list of them.
#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum OneOrMany<T> {
    Many(Vec<T>),
    One(T),
}

impl<T> OneOrMany<T> {
    pub fn into_vec(self) -> Vec<T> {
        match self {
            OneOrMany::Many(items) => items,
            OneOrMany::One(item) => vec![item],
        }
    }
}

/// A list setting, empty when it's missing.
pub fn list(value: Option<OneOrMany<String>>) -> Vec<String> {
    value.map(OneOrMany::into_vec).unwrap_or_default()
}

/// A YAML mapping; a document with nothing in it is the defaults.
pub fn parse_yaml<T: DeserializeOwned + Default>(text: &str, path: &str) -> Result<T> {
    let blank = text.lines().all(|line| {
        let line = line.trim();
        line.is_empty() || line.starts_with('#') || line == "---"
    });
    if blank {
        return Ok(T::default());
    }
    serde_saphyr::from_str(text).map_err(|e| anyhow!("{path}: {e}"))
}

pub fn read(path: &str) -> Result<String> {
    let bytes = std::fs::read(path).with_context(|| format!("Couldn't read {path}"))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

static REFERENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}").unwrap());

/// ${VAR} reads the environment, so a URL can carry an account id. The
/// client expands it when it sends, so commands that make no request don't
/// need every variable set.
pub fn expand(value: &str) -> Result<String> {
    for found in REFERENCE.captures_iter(value) {
        if std::env::var(&found[1]).unwrap_or_default().is_empty() {
            bail!("Set {} (used in {value})", &found[1]);
        }
    }
    Ok(REFERENCE
        .replace_all(value, |found: &regex::Captures| std::env::var(&found[1]).unwrap_or_default())
        .into_owned())
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct File {
    models: Option<OneOrMany<Value>>,
    threshold: Option<f64>,
    ignore: Option<OneOrMany<String>>,
    max_cost_usd: Option<f64>,
}

pub struct Config {
    pub models: Vec<Endpoint>,
    pub threshold: f64,
    pub ignore: Patterns,
    pub max_cost_usd: f64,
}

impl Config {
    /// +model+, from --model, replaces the file's models.
    pub fn load(path: Option<&str>, model: Option<&str>) -> Result<Config> {
        let file = path.unwrap_or(FILE);
        let mut data: File = if std::path::Path::new(file).exists() {
            parse_yaml(&read(file)?, file)?
        } else if path.is_some() {
            bail!("No config file at {file}");
        } else {
            File::default()
        };
        if let Some(model) = model {
            data.models = Some(OneOrMany::One(Value::String(model.to_string())));
        }
        let entries = data.models.map_or_else(|| vec![Value::String("typesafe".into())], OneOrMany::into_vec);
        if entries.is_empty() {
            bail!("models needs at least one model");
        }
        let models = entries.into_iter().map(Endpoint::new).collect::<Result<Vec<_>>>()?;
        let threshold = data.threshold.unwrap_or(0.7);
        if !(0.01..=1.0).contains(&threshold) {
            bail!("threshold must be a number between 0 and 1");
        }
        Ok(Config {
            models,
            threshold,
            ignore: Patterns::new(list(data.ignore))?,
            max_cost_usd: data.max_cost_usd.unwrap_or(1.0),
        })
    }

    pub fn warn_at(&self) -> f64 {
        (self.threshold - UNCERTAIN_BAND).max(0.0)
    }

    pub fn label(&self) -> String {
        self.models.iter().map(Endpoint::label).collect::<Vec<_>>().join(" + ")
    }
}

/// A model entry written as a mapping, for an endpoint judgelint has no
/// preset for or to change one.
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Settings {
    provider: Option<String>,
    model: Option<String>,
    api_base: Option<String>,
    path: Option<String>,
    protocol: Option<Protocol>,
    auth: Option<String>,
    api_key_env: Option<String>,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    #[serde(default)]
    provider_options: Map<String, Value>,
    price_per_million: Option<f64>,
    batch_size: Option<usize>,
    max_state_tokens: Option<usize>,
    max_request_tokens: Option<usize>,
}

/// One model to ask, and how to reach it: a provider preset and model id
/// ("typesafe", "cloudflare:clef", "openrouter:typesafe/jev-1.13"), or a
/// mapping.
#[derive(Clone)]
pub struct Endpoint {
    pub provider: String,
    pub model: Option<String>,
    pub api_base: Option<String>,
    pub path: String,
    pub protocol: Protocol,
    pub auth: String,
    pub api_key_env: Option<String>,
    pub headers: BTreeMap<String, String>,
    pub provider_options: Map<String, Value>,
    pub price_per_million: Option<f64>,
    pub batch_size: usize,
    pub max_state_tokens: usize,
    pub max_request_tokens: usize,
    pub needs: Option<String>,
}

impl Endpoint {
    fn new(entry: Value) -> Result<Endpoint> {
        let settings = match entry {
            Value::String(text) => {
                let (provider, model) = text.split_once(':').unwrap_or((&text, ""));
                Settings {
                    provider: (!provider.is_empty()).then(|| provider.to_string()),
                    model: (!model.is_empty()).then(|| model.to_string()),
                    ..Settings::default()
                }
            }
            other => serde_json::from_value(other).map_err(|e| anyhow!("models: {e}"))?,
        };
        let provider = settings.provider.unwrap_or_else(|| "custom".into());
        let preset = providers::find(&provider);
        let from_preset = |pick: fn(&providers::Preset) -> &Option<String>| preset.and_then(|p| pick(p).clone());
        let model = settings.model.or_else(|| from_preset(|p| &p.model));
        // A preset's prices are per model; another model has no price unless
        // the entry gives one, and its cost shows as unknown.
        let price_per_million = settings
            .price_per_million
            .or_else(|| preset.and_then(|p| p.prices.get(model.as_deref().unwrap_or("")).copied()));
        let count = |own: Option<usize>, preset: Option<usize>, default: usize, key: &str| -> Result<usize> {
            match own.or(preset).unwrap_or(default) {
                0 => bail!("models: {key} must be at least 1"),
                n => Ok(n),
            }
        };
        let auth = settings.auth.or_else(|| from_preset(|p| &p.auth)).unwrap_or_else(|| "bearer".into());
        if !(["bearer", "basic", "none"].contains(&auth.as_str()) || auth.starts_with("header:")) {
            bail!("auth is bearer, basic, none, or header:<name>, not {auth}");
        }
        Ok(Endpoint {
            api_base: settings.api_base.or_else(|| from_preset(|p| &p.api_base)),
            path: settings.path.or_else(|| from_preset(|p| &p.path)).unwrap_or_else(|| "/v1/systemone".into()),
            protocol: settings.protocol.or(preset.and_then(|p| p.protocol)).unwrap_or(Protocol::SystemOne),
            auth,
            api_key_env: settings.api_key_env.or_else(|| from_preset(|p| &p.api_key_env)),
            headers: settings.headers,
            provider_options: settings.provider_options,
            price_per_million,
            batch_size: count(settings.batch_size, preset.and_then(|p| p.batch_size), 32, "batch_size")?,
            // A request's state plus its widest question, and a whole request:
            // Jev's 32k and 64k token limits, with room for the estimate to be off.
            max_state_tokens: count(settings.max_state_tokens, None, 30_000, "max_state_tokens")?,
            max_request_tokens: count(settings.max_request_tokens, None, 60_000, "max_request_tokens")?,
            needs: from_preset(|p| &p.needs),
            provider,
            model,
        })
    }

    pub fn label(&self) -> String {
        format!("{}:{}", self.provider, self.model.as_deref().unwrap_or(""))
    }

    pub fn api_key(&self) -> Option<String> {
        let name = self.api_key_env.as_deref().filter(|n| !n.is_empty())?;
        std::env::var(name).ok().filter(|key| !key.is_empty())
    }
}
