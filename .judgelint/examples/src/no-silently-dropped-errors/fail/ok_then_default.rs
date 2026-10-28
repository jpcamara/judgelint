use std::fs;

#[derive(Default, serde::Deserialize)]
pub struct Settings {
    pub threshold: f64,
}

pub fn load_settings(path: &str) -> Settings {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}
