//! Requests and input tokens across a run, and what they cost. Decision
//! models bill input only, so input tokens are the cost. Shared by every
//! model's client in a run.

use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;

#[derive(Default)]
struct Totals {
    requests: u64,
    input_tokens: u64,
    cost: f64,
    unpriced: bool,
}

#[derive(Default)]
pub struct Usage {
    totals: Mutex<Totals>,
}

#[derive(Serialize)]
pub struct Summary {
    pub requests: u64,
    pub input_tokens: u64,
    pub cost_usd: Option<f64>,
}

/// 1234567 as "1,234,567".
pub fn delimit(number: u64) -> String {
    let digits = number.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

impl Usage {
    fn lock(&self) -> std::sync::MutexGuard<'_, Totals> {
        self.totals.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// OpenRouter reports each request's cost; for the rest it's tokens x the
    /// model's price. A request with neither makes the run's cost unknown.
    pub fn record(&self, response: &Value, price_per_million: Option<f64>) {
        let usage = &response["usage"];
        let tokens = usage["input_tokens"].as_f64().unwrap_or(0.0).max(0.0) as u64;
        let mut totals = self.lock();
        totals.requests += 1;
        totals.input_tokens += tokens;
        match (usage["cost"].as_f64(), price_per_million) {
            (Some(cost), _) => totals.cost += cost,
            (None, Some(price)) => totals.cost += tokens as f64 * price / 1_000_000.0,
            (None, None) => totals.unpriced = true,
        }
    }

    pub fn requests(&self) -> u64 {
        self.lock().requests
    }

    pub fn summary(&self) -> Summary {
        let totals = self.lock();
        Summary {
            requests: totals.requests,
            input_tokens: totals.input_tokens,
            cost_usd: (!totals.unpriced).then(|| (totals.cost * 1e6).round() / 1e6),
        }
    }

    pub fn line(&self) -> String {
        let Summary { requests, input_tokens, cost_usd } = self.summary();
        let cost = cost_usd.map_or_else(|| "cost unknown (no price for a model)".into(), |c| format!("${c:.4}"));
        let noun = if requests == 1 { "request" } else { "requests" };
        format!("judgelint: {requests} {noun}, {} input tokens, {cost}", delimit(input_tokens))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn delimits() {
        assert_eq!(super::delimit(0), "0");
        assert_eq!(super::delimit(999), "999");
        assert_eq!(super::delimit(1000), "1,000");
        assert_eq!(super::delimit(1234567), "1,234,567");
    }

    #[test]
    fn records_requests_tokens_and_cost() {
        let usage = super::Usage::default();
        for _ in 0..2 {
            usage.record(&serde_json::json!({"usage": {"input_tokens": 500_000}}), Some(0.042));
        }
        let summary = usage.summary();
        assert_eq!((summary.requests, summary.input_tokens, summary.cost_usd), (2, 1_000_000, Some(0.042)));
        assert_eq!(usage.line(), "judgelint: 2 requests, 1,000,000 input tokens, $0.0420");
    }

    #[test]
    fn prefers_the_cost_a_provider_reports() {
        let usage = super::Usage::default();
        usage.record(&serde_json::json!({"usage": {"input_tokens": 300, "cost": 0.0005}}), Some(0.042));
        assert_eq!(usage.summary().cost_usd, Some(0.0005));
    }
}
