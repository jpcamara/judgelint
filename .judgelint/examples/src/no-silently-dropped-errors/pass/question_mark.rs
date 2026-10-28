use std::fs;
use std::path::Path;

pub fn save_report(path: &Path, report: &str) -> std::io::Result<()> {
    fs::write(path, report)?;
    Ok(())
}
