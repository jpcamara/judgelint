pub fn retry_limit(text: &str) -> u32 {
    text.trim().parse().unwrap_or_default()
}
