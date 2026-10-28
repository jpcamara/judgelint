use std::fs;
use std::path::PathBuf;

pub fn read_all(paths: &[PathBuf]) -> Vec<String> {
    let mut texts = Vec::new();
    for path in paths {
        if let Ok(text) = fs::read_to_string(path) {
            texts.push(text);
        }
    }
    texts
}
