use std::fs;

pub fn load_settings(path: &str) -> Settings {
    match fs::read_to_string(path) {
        Ok(text) => parse(&text),
        Err(error) => {
            eprintln!("judgelint: couldn't read {path} ({error}), so using the defaults");
            Settings::default()
        }
    }
}
