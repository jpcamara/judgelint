use std::fs;
use std::path::Path;

pub fn save_report(path: &Path, report: &str) {
    let _ = fs::write(path, report);
}
