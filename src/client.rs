//! Asks one model (an Endpoint) the questions over HTTP, in whichever
//! protocol its provider speaks. Connections are kept open for the next
//! request, from any thread.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use serde_json::Value;

use crate::config::{self, Endpoint, RETRIES, TIMEOUT};
use crate::protocol::{Answer, Protocol};
use crate::question::Question;
use crate::usage::Usage;

const RETRY_STATUSES: [u16; 7] = [408, 429, 500, 502, 503, 504, 529];
/// Answers are a few kilobytes; anything near this is something else.
const MAX_RESPONSE_BYTES: u64 = 16 << 20;

pub struct Client {
    pub endpoint: Endpoint,
    usage: Arc<Usage>,
    agent: ureq::Agent,
    url: OnceLock<String>,
    /// The payload's length without the state or questions, and whether the
    /// state is in it (provider_options can replace it).
    base: (usize, bool),
}

impl Client {
    pub fn new(endpoint: Endpoint, usage: Arc<Usage>) -> Result<Client> {
        let provider = &endpoint.provider;
        if endpoint.api_base.as_deref().unwrap_or("").is_empty() {
            bail!("Provider {provider} needs {} in .judgelint.yml", endpoint.needs.as_deref().unwrap_or("api_base"));
        }
        // llama.cpp serves one model and doesn't need its name; nothing else can guess it.
        if endpoint.model.as_deref().unwrap_or("").is_empty() && provider != "llamacpp" {
            bail!("Provider {provider} needs a model in .judgelint.yml");
        }
        if let Some(base) = endpoint.api_base.as_deref().filter(|b| !b.contains("${")) {
            refuse_plain_http(base, base)?;
        }
        let protocol = endpoint.protocol;
        let empty =
            protocol.payload(endpoint.model.as_deref(), &[], Value::String(String::new()), &endpoint.provider_options);
        let has_state = !endpoint.provider_options.contains_key(protocol.state_key());
        let base = (empty.to_string().len() - if has_state { 2 } else { 0 }, has_state);
        // No redirects: a hop to another host would carry a custom auth header along.
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .max_redirects(0)
            .timeout_global(Some(Duration::from_secs(2 * TIMEOUT)))
            .timeout_connect(Some(Duration::from_secs(TIMEOUT)))
            .timeout_recv_response(Some(Duration::from_secs(TIMEOUT)))
            .timeout_recv_body(Some(Duration::from_secs(TIMEOUT)))
            .max_idle_connections(256)
            .max_idle_connections_per_host(256)
            .user_agent("judgelint")
            .build()
            .into();
        Ok(Client { endpoint, usage, agent, url: OnceLock::new(), base })
    }

    pub fn protocol(&self) -> Protocol {
        self.endpoint.protocol
    }

    /// A conservative token count for code: three bytes a token. +state_len+
    /// is the length of the state's JSON in this protocol.
    pub fn tokens(&self, state_len: usize) -> usize {
        (self.base.0 + if self.base.1 { state_len } else { 0 }) / 3
    }

    /// Called before the first request, so a run the cache answers needs no key.
    pub fn check_key(&self) -> Result<()> {
        let env = self.endpoint.api_key_env.as_deref().unwrap_or("");
        if self.endpoint.auth != "none" && !env.is_empty() && self.endpoint.api_key().is_none() {
            bail!("Set {env} to your {} API key", self.endpoint.provider);
        }
        Ok(())
    }

    fn url(&self) -> Result<&str> {
        if let Some(url) = self.url.get() {
            return Ok(url);
        }
        let base = config::expand(self.endpoint.api_base.as_deref().unwrap_or(""))?;
        let path =
            config::expand(&self.endpoint.path)?.replace("{model}", self.endpoint.model.as_deref().unwrap_or(""));
        let url = format!("{}/{}", base.trim_end_matches('/'), path.trim_start_matches('/'));
        refuse_plain_http(&url, &self.shown_url())?;
        Ok(self.url.get_or_init(|| url))
    }

    /// The URL as configured, before ${VAR} is filled in, so errors don't
    /// print what the environment holds.
    fn shown_url(&self) -> String {
        let base = self.endpoint.api_base.as_deref().unwrap_or("");
        format!("{}/{}", base.trim_end_matches('/'), self.endpoint.path.trim_start_matches('/'))
    }

    /// Each question's answer, or None for one the model refused.
    pub fn judge(&self, state: Value, questions: &[&Question]) -> Result<Vec<Option<Answer>>> {
        let endpoint = &self.endpoint;
        let payload = self.protocol().payload(endpoint.model.as_deref(), questions, state, &endpoint.provider_options);
        let data = unwrap(self.post(&serde_json::to_vec(&payload)?)?);
        self.usage.record(&data, endpoint.price_per_million);
        self.protocol().parse(&data, questions)
    }

    fn post(&self, body: &[u8]) -> Result<Value> {
        let label = self.endpoint.label();
        let url = self.url()?;
        for attempt in 1.. {
            let failure = match self.send(url, body) {
                Ok((code, retry_after, response)) => {
                    if (200..300).contains(&code) {
                        return serde_json::from_slice(&response).map_err(|_| {
                            anyhow!("{label} answered with something other than JSON: {}", first_bytes(&response))
                        });
                    }
                    if !RETRY_STATUSES.contains(&code) || attempt > RETRIES {
                        bail!("{label} answered {code}: {}", error_detail(&response));
                    }
                    let delay = retry_after
                        .and_then(|a| a.trim().parse::<f64>().ok())
                        .filter(|a| a.is_finite())
                        .map(|a| a.clamp(0.0, 30.0));
                    std::thread::sleep(Duration::from_secs_f64(delay.unwrap_or(0.5 * 2f64.powi(attempt as i32 - 1))));
                    continue;
                }
                Err(failure) => failure,
            };
            // Nothing listening isn't going to change in a few seconds; a dropped
            // or stalled connection might.
            let refused = matches!(&failure, ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused);
            let too_large = matches!(&failure, ureq::Error::BodyExceedsLimit(_));
            if refused || too_large || attempt > RETRIES {
                bail!("Couldn't reach {label} at {}: {failure}", self.shown_url());
            }
            std::thread::sleep(Duration::from_secs_f64(2f64.powi(attempt as i32)));
        }
        unreachable!("the loop returns")
    }

    /// The response's status, Retry-After header, and body.
    fn send(&self, url: &str, body: &[u8]) -> Result<(u16, Option<String>, Vec<u8>), ureq::Error> {
        let mut request =
            self.agent.post(url).header("Content-Type", "application/json").header("Accept", "application/json");
        if let Some(key) = self.endpoint.api_key() {
            match self.endpoint.auth.as_str() {
                "bearer" => request = request.header("Authorization", format!("Bearer {key}")),
                "basic" => {
                    let token = base64::engine::general_purpose::STANDARD.encode(format!("token:{key}"));
                    request = request.header("Authorization", format!("Basic {token}"));
                }
                "none" => {}
                header => request = request.header(header.trim_start_matches("header:"), key),
            }
        }
        for (name, value) in &self.endpoint.headers {
            request = request.header(name, config::expand(value).unwrap_or_else(|_| value.clone()));
        }
        let mut response = request.send(body)?;
        let code = response.status().as_u16();
        let retry_after = response.headers().get("Retry-After").and_then(|v| v.to_str().ok()).map(str::to_string);
        let body = response.body_mut().with_config().limit(MAX_RESPONSE_BYTES).read_to_vec()?;
        Ok((code, retry_after, body))
    }
}

/// Code and keys go over https, except to this machine. +shown+ is the URL
/// as configured, for the error.
fn refuse_plain_http(url: &str, shown: &str) -> Result<()> {
    if !url.starts_with("http://") || config::is_local(url) {
        return Ok(());
    }
    bail!("{shown} isn't https; judgelint sends code and keys over plain http only to localhost")
}

fn first_bytes(bytes: &[u8]) -> String {
    String::from_utf8_lossy(&bytes[..bytes.len().min(200)]).into_owned()
}

/// Cloudflare wraps the answers as {result: {...}, success, errors}.
fn unwrap(data: Value) -> Value {
    if data.get("answers").is_none() && data.get("result").is_some_and(|r| r.get("answers").is_some()) {
        return data["result"].clone();
    }
    data
}

/// The error message, whichever of the shapes providers use: TypeSafe's
/// detail (a string, {message}, or a validation list), OpenAI's
/// {error: {message}}, Cloudflare's errors list, or a bare message.
fn error_detail(body: &[u8]) -> String {
    let Ok(Value::Object(data)) = serde_json::from_slice::<Value>(body) else {
        return first_bytes(body);
    };
    let present = |v: &&Value| !matches!(v, Value::Null | Value::Bool(false));
    ["detail", "error", "errors", "message"]
        .iter()
        .find_map(|k| data.get(*k).filter(present))
        .and_then(message)
        .map(|m| m.chars().take(300).collect())
        .unwrap_or_else(|| first_bytes(body))
}

fn message(detail: &Value) -> Option<String> {
    match detail {
        Value::String(s) => (!s.is_empty()).then(|| s.clone()),
        Value::Object(h) => h.get("message").or_else(|| h.get("msg")).and_then(message),
        Value::Array(items) => {
            let found: Vec<String> = items.iter().filter_map(message).collect();
            (!found.is_empty()).then(|| found.join("; "))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::providers;

    fn client(entry: Value) -> Result<Client> {
        Client::new(Endpoint::new(entry)?, Arc::default())
    }

    // Error bodies from TypeSafe, Celeris, OpenAI, OpenRouter, and Cloudflare,
    // plus Vercel's and the local proxies' shapes.
    #[test]
    fn details() {
        let shapes = [
            (
                r#"{"detail":{"error_type":"authentication_error","message":"Cannot authenticate."}}"#,
                "Cannot authenticate.",
            ),
            (r#"{"detail":[{"loc":["body","bogus"],"msg":"unknown field","type":"value_error"}]}"#, "unknown field"),
            (r#"{"detail":[{"msg":"a"},{"msg":"b"}]}"#, "a; b"),
            (r#"{"detail":"bad key"}"#, "bad key"),
            (
                r#"{"error":{"message":"The model `nope` does not exist.","type":"invalid_request_error"}}"#,
                "The model `nope` does not exist.",
            ),
            (r#"{"error":{"message":"Model nope/nope does not exist","code":400}}"#, "Model nope/nope does not exist"),
            (
                r#"{"errors":[{"message":"AiError: Bad input","code":5006}],"success":false,"result":{}}"#,
                "AiError: Bad input",
            ),
            (r#"{"message":"Unauthorized","error_type":"auth"}"#, "Unauthorized"),
            (r#"{"error":"invalid model"}"#, "invalid model"),
            ("<html>Bad Gateway</html>", "<html>Bad Gateway</html>"),
        ];
        for (body, message) in shapes {
            assert_eq!(error_detail(body.as_bytes()), message, "{body}");
        }
    }

    #[test]
    fn says_what_a_preset_still_needs() {
        let error = |entry| client(entry).err().unwrap().to_string();
        assert!(
            error(json!({"provider": "foundry", "model": "m"}))
                .contains("foundry needs api_base (your Foundry resource endpoint)")
        );
        assert!(error(json!({"provider": "ollama"})).contains("ollama needs a model"));
        assert!(error(json!({"provider": "acme", "model": "m"})).contains("acme needs api_base"));
    }

    // Every preset resolves to the endpoint its provider documents.
    #[test]
    fn preset_urls() {
        let expected = [
            ("typesafe", "https://api.typesafe.ai/v1/systemone"),
            ("openrouter", "https://openrouter.ai/api/v1/systemone"),
            ("celeris", "https://inference.celeris.ai/celeris-1-decision/v1/systemone"),
            ("cloudflare", "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/cloudflare/clef"),
            ("openai", "https://api.openai.com/v1/decisions"),
            ("perplexity", "https://api.perplexity.ai/v1/decisions"),
            ("vercel", "https://ai-gateway.vercel.sh/typesafe/v1/systemone"),
            ("digitalocean", "https://inference.do-ai.run/v1/systemone"),
            ("upstage", "https://api.upstage.ai/v1/systemone"),
            ("hanzo", "https://api.hanzo.ai/v1/decisions"),
            ("foundry", "https://example.services.ai.azure.com/providers/microsoft/v1/systemone"),
            ("databricks", "https://example.cloud.databricks.com/ai-gateway/typesafe/v1/systemone"),
            ("ollama", "http://localhost:11434/v1/systemone"),
            ("llamacpp", "http://localhost:8080/v1/systemone"),
            ("vllm", "http://localhost:8000/v1/systemone"),
            ("litellm", "http://localhost:4000/v1/systemone"),
        ];
        let mut names: Vec<&str> = providers::all().iter().map(|p| p.name.as_str()).collect();
        let mut listed: Vec<&str> = expected.iter().map(|(name, _)| *name).collect();
        names.sort_unstable();
        listed.sort_unstable();
        assert_eq!(names, listed);
        for (provider, url) in expected {
            let mut entry = json!({"provider": provider});
            match provider {
                "foundry" => entry["api_base"] = json!("https://example.services.ai.azure.com"),
                "databricks" => entry["api_base"] = json!("https://example.cloud.databricks.com"),
                // The test can't set CLOUDFLARE_ACCOUNT_ID for the preset's
                // ${CLOUDFLARE_ACCOUNT_ID}, so it fills it in.
                "cloudflare" => {
                    let base = providers::find("cloudflare").unwrap().api_base.clone().unwrap();
                    entry["api_base"] = json!(base.replace("${CLOUDFLARE_ACCOUNT_ID}", "acct"));
                }
                _ => {}
            }
            if providers::find(provider).unwrap().model.is_none() {
                entry["model"] = json!("m");
            }
            assert_eq!(client(entry).unwrap().url().unwrap(), url, "{provider}");
        }
    }

    #[test]
    fn plain_http_only_to_this_machine() {
        assert!(refuse_plain_http("http://127.0.0.1:9/v1", "x").is_ok());
        assert!(refuse_plain_http("https://api.example.com/v1", "x").is_ok());
        let error = refuse_plain_http("http://api.example.com/key-123", "http://api.example.com/${KEY}").unwrap_err();
        assert!(error.to_string().contains("${KEY}") && !error.to_string().contains("key-123"), "{error}");
    }
}
