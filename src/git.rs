//! Runs git. Nothing a repository's config names runs on its behalf: no file
//! system monitor here, and the callers turn off diff drivers and text
//! converters. Messages are in English, so a failure can be told from a
//! directory that isn't a repository.

use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Result, anyhow, bail};

pub fn command(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command.current_dir(dir).env("LC_ALL", "C").stdin(Stdio::null()).args([
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.quotePath=false",
    ]);
    command
}

/// What git prints, or an error with the first line of what it said went wrong.
pub fn run(dir: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let output = command(dir).args(args).output().map_err(|e| anyhow!("Couldn't run git: {e}"))?;
    if !output.status.success() {
        bail!("git {} failed: {}", args.first().unwrap_or(&""), first_line(&output.stderr));
    }
    Ok(output.stdout)
}

pub fn first_line(stderr: &[u8]) -> String {
    String::from_utf8_lossy(stderr).trim().lines().next().unwrap_or("").trim().to_string()
}

/// In a git repository, the files git tracks, and those it would add when
/// +untracked+; None outside one. Any other failure is an error, since
/// without the list an ignored file could be sent.
pub fn files(dir: &Path, untracked: bool) -> Result<Option<Vec<String>>> {
    let mut args = vec!["ls-files", "-z", "--cached"];
    if untracked {
        args.extend(["--others", "--exclude-standard"]);
    }
    let output = match command(dir).args(&args).output() {
        Ok(output) => output,
        // No git, and no repository it was needed for.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound && !dir.ancestors().any(|d| d.join(".git").exists()) => {
            return Ok(None);
        }
        Err(e) => bail!("Couldn't run git to list the project's files: {e}"),
    };
    if !output.status.success() {
        let said = first_line(&output.stderr);
        if said.contains("not a git repository") {
            return Ok(None);
        }
        bail!("git couldn't list the project's files: {said}");
    }
    let mut files: Vec<String> = output
        .stdout
        .split(|&b| b == 0)
        .filter(|p| !p.is_empty())
        .filter_map(|p| std::str::from_utf8(p).ok().map(str::to_string))
        .collect();
    files.sort_unstable();
    files.dedup();
    Ok(Some(files))
}
