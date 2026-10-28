use anyhow::{Context, Result};

pub fn retry_limit(text: &str) -> Result<u32> {
    text.trim()
        .parse()
        .with_context(|| format!("retry limit {text:?} isn't a number"))
}
