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
        let protocol = endpoint.protocol;
        let empty =
            protocol.payload(endpoint.model.as_deref(), &[], Value::String(String::new()), &endpoint.provider_options);
        let has_state = !endpoint.provider_options.contains_key(protocol.state_key());
        let base = (empty.to_string().len() - if has_state { 2 } else { 0 }, has_state);
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
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
        Ok(self.url.get_or_init(|| url))
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
                    let delay = retry_after.and_then(|a| a.trim().parse::<f64>().ok()).map(|a| a.clamp(0.0, 30.0));
                    std::thread::sleep(Duration::from_secs_f64(delay.unwrap_or(0.5 * 2f64.powi(attempt as i32 - 1))));
                    continue;
                }
                Err(failure) => failure,
            };
            // Nothing listening isn't going to change in a few seconds; a dropped
            // or stalled connection might.
            let refused = matches!(&failure, ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused);
            if refused || attempt > RETRIES {
                bail!("Couldn't reach {label} at {url}: {failure}");
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
        let body = response.body_mut().with_config().limit(u64::MAX).read_to_vec()?;
        Ok((code, retry_after, body))
    }
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
    use super::*;

    #[test]
    fn details() {
        assert_eq!(error_detail(br#"{"detail":[{"msg":"a"},{"msg":"b"}]}"#), "a; b");
        assert_eq!(error_detail(br#"{"error":{"message":"nope"}}"#), "nope");
        assert_eq!(error_detail(b"plain"), "plain");
    }
}
