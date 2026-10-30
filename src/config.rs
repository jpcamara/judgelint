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

use anyhow::{Result, anyhow, bail};
use regex::Regex;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::changes::Commit;
use crate::glob::Patterns;
use crate::project::{self, Project};
use crate::protocol::Protocol;
use crate::providers;

pub const FILE: &str = ".judgelint.yml";
pub const RULES_DIR: &str = ".judgelint/rules";
pub const CACHE: &str = ".judgelint/cache.bin";
pub const WINDOW_LINES: u32 = 40;
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

/// Whether a URL is on this machine: localhost, or a loopback address like
/// 127.0.0.1 or ::1.
pub fn is_local(url: &str) -> bool {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    let host = match host.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => host.split(':').next().unwrap_or(""),
    };
    host.eq_ignore_ascii_case("localhost") || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
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
    /// +model+, from --model, replaces the file's models. With a commit, the
    /// file is read from it, unless it's named by an absolute path. A config
    /// named with --config can be anywhere; the project's own is read like
    /// a file to send.
    pub fn load(project: &Project, path: Option<&str>, model: Option<&str>, commit: Option<&Commit>) -> Result<Config> {
        let file = path.unwrap_or(FILE);
        let text = match (commit.filter(|_| !file.starts_with('/')), path) {
            (Some(commit), _) => commit.read(file)?.map(|bytes| String::from_utf8_lossy(&bytes).into_owned()),
            (None, Some(named)) => Some(project::read_named_config(named)?),
            (None, None) => project.read_config(FILE)?,
        };
        let mut data: File = match text {
            Some(text) => parse_yaml(&text, file)?,
            None if path.is_some() => bail!("No config file at {file}"),
            None => File::default(),
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
    /// What its answers are cached under: the provider and model, plus how
    /// it's asked when that isn't the preset's way, in which case the
    /// client adds the address it resolves to.
    pub cache_label: String,
    /// Asked the preset's way, at the preset's address.
    pub as_preset: bool,
}

impl Endpoint {
    pub fn new(entry: Value) -> Result<Endpoint> {
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
        // A server on this machine costs nothing.
        let local = settings.api_base.as_deref().or_else(|| preset.and_then(|p| p.api_base.as_deref()));
        let local = local.is_some_and(|base| expand(base).is_ok_and(|base| is_local(&base)));
        let price_per_million = settings
            .price_per_million
            .or_else(|| preset.and_then(|p| p.prices.get(model.as_deref().unwrap_or("")).copied()))
            .or(local.then_some(0.0));
        let count = |own: Option<usize>, preset: Option<usize>, default: usize, key: &str| -> Result<usize> {
            match own.or(preset).unwrap_or(default) {
                0 => bail!("models: {key} must be at least 1"),
                n => Ok(n),
            }
        };
        let auth = settings.auth.or_else(|| from_preset(|p| &p.auth)).unwrap_or_else(|| "bearer".into());
        // A preset's key goes only to the preset's own address, and its
        // answers are cached apart from those of anything else.
        let moved = settings.api_base.is_some() && settings.api_base != from_preset(|p| &p.api_base);
        let as_preset = !moved
            && settings.path.is_none()
            && settings.protocol.is_none()
            && settings.provider_options.is_empty()
            && settings.headers.is_empty()
            && preset.is_some();
        let api_key_env = settings.api_key_env.or_else(|| if moved { None } else { from_preset(|p| &p.api_key_env) });
        let api_base = settings.api_base.or_else(|| from_preset(|p| &p.api_base));
        let path = settings.path.or_else(|| from_preset(|p| &p.path)).unwrap_or_else(|| "/v1/systemone".into());
        let protocol = settings.protocol.or(preset.and_then(|p| p.protocol)).unwrap_or(Protocol::SystemOne);
        let own_label = format!("{provider}/{}", model.as_deref().unwrap_or(""));
        let cache_label = if as_preset {
            own_label
        } else {
            let options = Value::Object(settings.provider_options.clone());
            format!("{own_label} {path} {protocol:?} {options} {:?}", settings.headers)
        };
        if !(["bearer", "basic", "none"].contains(&auth.as_str()) || auth.starts_with("header:")) {
            bail!("auth is bearer, basic, none, or header:<name>, not {auth}");
        }
        Ok(Endpoint {
            api_base,
            path,
            protocol,
            auth,
            api_key_env,
            cache_label,
            as_preset,
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::testing::TempDir;

    /// The config a .judgelint.yml of +yaml+ gives, with --model +model+.
    fn load(yaml: &str, model: Option<&str>) -> Result<Config> {
        let dir = TempDir::new();
        Config::load(&dir.project(), Some(&dir.write(FILE, yaml)), model, None)
    }

    fn labels(config: &Config) -> Vec<String> {
        config.models.iter().map(Endpoint::label).collect()
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn defaults_to_jev_on_typesafe() {
        let config = load("", None).unwrap();
        let jev = &config.models[0];
        assert_eq!(labels(&config), ["typesafe:jev-latest"]);
        assert_eq!(jev.api_base.as_deref(), Some("https://api.typesafe.ai"));
        assert_eq!(jev.api_key_env.as_deref(), Some("TYPESAFE_API_KEY"));
        assert_eq!(jev.price_per_million, Some(0.042));
        assert!(close(config.threshold, 0.7) && close(config.warn_at(), 0.4) && close(config.max_cost_usd, 1.0));
    }

    #[test]
    fn models_as_provider_and_model() {
        let config =
            load("models: [typesafe, \"cloudflare:clef\", \"openrouter:typesafe/jev-1.13\"]\nthreshold: 0.6\n", None)
                .unwrap();
        assert_eq!(labels(&config), ["typesafe:jev-latest", "cloudflare:clef", "openrouter:typesafe/jev-1.13"]);
        assert!(close(config.threshold, 0.6) && close(config.warn_at(), 0.3));
    }

    #[test]
    fn the_model_flag_replaces_the_files_models() {
        let config = load("models: [typesafe, cloudflare]\nthreshold: 0.6\n", Some("openai")).unwrap();
        assert_eq!(labels(&config), ["openai:gpt-6-luna"]);
        assert!(close(config.threshold, 0.6));
    }

    #[test]
    fn a_custom_endpoint() {
        let custom = Endpoint::new(json!({
            "api_base": "https://gateway.example.com", "model": "decider", "auth": "none",
            "protocol": "decisions", "price_per_million": 0.5, "batch_size": 8,
        }))
        .unwrap();
        assert_eq!(custom.label(), "custom:decider");
        assert_eq!((custom.protocol, custom.auth.as_str(), custom.batch_size), (Protocol::Decisions, "none", 8));
        assert_eq!(custom.price_per_million, Some(0.5));
    }

    #[test]
    fn presets_fill_protocol_path_auth_and_limits() {
        let endpoint = |entry| Endpoint::new(entry).unwrap();
        let openai = endpoint(json!({"provider": "openai"}));
        assert_eq!(
            (openai.protocol, openai.path.as_str(), openai.auth.as_str()),
            (Protocol::Decisions, "/v1/decisions", "bearer")
        );

        // Perplexity takes System One bodies at /v1/decisions.
        let perplexity = endpoint(json!({"provider": "perplexity"}));
        assert_eq!((perplexity.protocol, perplexity.path.as_str()), (Protocol::SystemOne, "/v1/decisions"));

        let cloudflare = endpoint(json!({"provider": "cloudflare"}));
        assert_eq!(cloudflare.path, "/@cf/cloudflare/{model}");
        assert_eq!(cloudflare.batch_size, 64);
        assert!(
            cloudflare.api_base.unwrap().contains("${CLOUDFLARE_ACCOUNT_ID}"),
            "the client expands it when it sends"
        );

        assert_eq!(endpoint(json!({"provider": "typesafe", "model": "some-new-jev"})).price_per_million, None);
    }

    #[test]
    fn rejects_unknown_keys_and_bad_values() {
        for yaml in
            ["provider: typesafe\n", "threshold: high\n", "threshold: 2\n", "models: []\n", "models: [{modle: x}]\n"]
        {
            assert!(load(yaml, None).is_err(), "{yaml}");
        }
    }

    #[test]
    fn numbers_in_exponent_form() {
        assert!(close(load("max_cost_usd: 1.0e-07\n", None).unwrap().max_cost_usd, 1e-7));
    }

    #[test]
    fn a_preset_moved_elsewhere_loses_its_key_and_its_cache() {
        let preset = Endpoint::new(json!("typesafe")).unwrap();
        let moved = Endpoint::new(json!({"provider": "typesafe", "api_base": "https://elsewhere.example"})).unwrap();
        assert_eq!(moved.api_key_env, None);
        assert_eq!(preset.cache_label, "typesafe/jev-latest");
        assert_ne!(moved.cache_label, preset.cache_label);
        let named = json!({"provider": "typesafe", "api_base": "https://elsewhere.example", "api_key_env": "MINE"});
        assert_eq!(Endpoint::new(named).unwrap().api_key_env.as_deref(), Some("MINE"));
        let same = json!({"provider": "typesafe", "api_base": "https://api.typesafe.ai"});
        assert_eq!(Endpoint::new(same).unwrap().cache_label, preset.cache_label);
    }

    #[test]
    fn servers_on_this_machine_cost_nothing() {
        for local in ["http://localhost:8080", "http://127.0.0.1", "http://[::1]:1/v1", "https://user@localhost"] {
            assert!(is_local(local), "{local}");
        }
        for remote in
            ["https://api.typesafe.ai", "http://localhost.example.com", "http://10.0.0.1", "http://127.example.com"]
        {
            assert!(!is_local(remote), "{remote}");
        }
        let custom = |base: &str| Endpoint::new(json!({"api_base": base, "model": "m"})).unwrap().price_per_million;
        assert_eq!(custom("http://localhost:8080"), Some(0.0));
        assert_eq!(custom("https://gateway.example.com"), None);
    }
}
