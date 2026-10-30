//! Paths: matching rule patterns, and finding the files and directories they
//! name. In a git repository the files to check are those git tracks or would
//! add; elsewhere they're found on disk.
//!
//! `*` stays within a directory, `**/` spans any number of them, and `{a,b}`
//! alternates. Wildcards don't match names that start with a dot. A walk
//! doesn't follow links into directories under `**`, though a literal
//! directory in a pattern can be a link, and a link to a file is the file.

use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock, mpsc};

use anyhow::{Context, Result, anyhow, bail};
use globset::{Glob, GlobBuilder, GlobSet, GlobSetBuilder};
use ignore::{WalkBuilder, WalkState};

fn compile(pattern: &str) -> Result<Glob> {
    GlobBuilder::new(pattern).literal_separator(true).build().with_context(|| format!("Bad pattern {pattern}"))
}

/// A path with a part that starts with a dot.
fn hidden(path: &str) -> bool {
    path.split('/').any(|part| part.starts_with('.') && part != "." && part != "..")
}

/// A list of patterns to match paths against.
pub struct Patterns {
    pub raw: Vec<String>,
    set: GlobSet,
    /// Which patterns name a dotted part, and so can match a hidden path.
    dotted: Vec<bool>,
}

impl Patterns {
    pub fn new(raw: Vec<String>) -> Result<Patterns> {
        let mut set = GlobSetBuilder::new();
        for pattern in &raw {
            set.add(compile(pattern)?);
        }
        let dotted = raw.iter().map(|p| hidden(p)).collect();
        Ok(Patterns { set: set.build()?, dotted, raw })
    }

    pub fn is_match(&self, path: &str) -> bool {
        if hidden(path) { self.set.matches(path).into_iter().any(|i| self.dotted[i]) } else { self.set.is_match(path) }
    }
}

/// A path found on disk, and whether it's a directory (or a link to one).
#[derive(Clone)]
pub struct Entry {
    pub path: String,
    pub dir: bool,
}

/// What's under the working directory, outside hidden directories, listed
/// once and shared by the globs that look there.
static TREE: Mutex<Option<Arc<Vec<Entry>>>> = Mutex::new(None);

/// Lets go of the listing once the files are found.
pub fn release() {
    *TREE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

fn tree() -> Arc<Vec<Entry>> {
    let mut tree = TREE.lock().unwrap_or_else(|e| e.into_inner());
    tree.get_or_insert_with(|| Arc::new(walk(Path::new("."), true, None, false))).clone()
}

/// Everything under +root+, as paths relative to it.
fn walk(root: &Path, skip_hidden: bool, max_depth: Option<usize>, follow_links: bool) -> Vec<Entry> {
    let (sender, found) = mpsc::channel();
    WalkBuilder::new(root)
        .standard_filters(false)
        .hidden(skip_hidden)
        .follow_links(follow_links)
        .max_depth(max_depth)
        .threads(crate::FILE_THREADS)
        .build_parallel()
        .run(|| {
            let sender = sender.clone();
            Box::new(move |entry| {
                if let Ok(entry) = entry
                    && entry.depth() > 0
                    && let Some(dir) = is_dir(&entry)
                {
                    let path = entry.path().strip_prefix(root).unwrap_or(entry.path());
                    let _ = sender.send(Entry { path: path.to_string_lossy().into_owned(), dir });
                }
                WalkState::Continue
            })
        });
    drop(sender);
    found.into_iter().collect()
}

/// Files and directories, following a link to see which it leads to. Broken
/// links, sockets and the like are neither.
fn is_dir(entry: &ignore::DirEntry) -> Option<bool> {
    let kind = entry.file_type()?;
    let kind = if kind.is_symlink() { fs::metadata(entry.path()).ok()?.file_type() } else { kind };
    (kind.is_file() || kind.is_dir()).then(|| kind.is_dir())
}

/// A directory the tree listing covers: relative, plain, and not reached
/// through a link.
fn in_tree(base: &str) -> bool {
    if base.starts_with('/') {
        return false;
    }
    let mut path = PathBuf::new();
    for part in base.split('/').filter(|p| !p.is_empty()) {
        if part == "." || part == ".." {
            return false;
        }
        path.push(part);
        if fs::symlink_metadata(&path).map_or(true, |m| m.file_type().is_symlink()) {
            return false;
        }
    }
    true
}

/// The files and directories a pattern matches, sorted.
pub fn find(pattern: &str) -> Result<Vec<Entry>> {
    let parts: Vec<&str> = pattern.split('/').collect();
    let literal = parts.iter().take_while(|p| !p.contains(['*', '?', '[', '{', '\\'])).count();
    if literal == parts.len() {
        return Ok(fs::metadata(pattern)
            .map(|m| Entry { path: pattern.to_string(), dir: m.is_dir() })
            .into_iter()
            .collect());
    }
    let base = parts[..literal].join("/");
    let rest = parts[literal..].join("/");
    let matcher = compile(pattern)?.compile_matcher();
    let mut found: Vec<Entry> = if !hidden(pattern) && in_tree(&base) {
        let prefix = if base.is_empty() { String::new() } else { format!("{base}/") };
        tree().iter().filter(|e| e.path.starts_with(&prefix) && matcher.is_match(&e.path)).cloned().collect()
    } else {
        // `base/.` walks through a link at the base.
        let root = if base.is_empty() { ".".to_string() } else { format!("{base}/.") };
        let recursive = rest.contains("**");
        let depth = (!recursive).then(|| parts.len() - literal);
        walk(Path::new(&root), !hidden(&rest), depth, !recursive)
            .into_iter()
            .map(|e| Entry { path: if base.is_empty() { e.path } else { format!("{base}/{}", e.path) }, dir: e.dir })
            .filter(|e| matcher.is_match(&e.path))
            .collect()
    };
    found.sort_unstable_by(|a, b| a.path.cmp(&b.path));
    Ok(found)
}

/// The files the patterns match, sorted.
pub fn expand(patterns: &[String]) -> Result<Vec<String>> {
    let mut files = Vec::new();
    for pattern in patterns {
        files.extend(find(pattern)?.into_iter().filter(|e| !e.dir).map(|e| e.path));
    }
    files.sort_unstable();
    files.dedup();
    Ok(files)
}

/// The directories a pattern matches, sorted.
pub fn directories(pattern: &str) -> Result<Vec<String>> {
    Ok(find(pattern)?.into_iter().filter(|e| e.dir).map(|e| e.path).collect())
}

/// In a git repository, the files git tracks or would add, sorted; None
/// outside one. Git is asked once a run.
fn project_files() -> Option<Arc<Vec<String>>> {
    static FILES: OnceLock<Option<Arc<Vec<String>>>> = OnceLock::new();
    FILES
        .get_or_init(|| {
            let output = Command::new("git")
                .args(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()?;
            if !output.status.success() {
                return None;
            }
            let mut files: Vec<String> = String::from_utf8_lossy(&output.stdout)
                .split('\0')
                .filter(|p| !p.is_empty())
                .map(str::to_string)
                .collect();
            files.sort_unstable();
            files.dedup();
            Some(Arc::new(files))
        })
        .clone()
}

/// The files to check: in a git repository, those git tracks or would add;
/// elsewhere, every file the patterns match.
pub fn files(patterns: &Patterns) -> Result<Vec<String>> {
    match project_files() {
        Some(listed) => Ok(listed.iter().filter(|p| patterns.is_match(p) && is_file(p)).cloned().collect()),
        None => expand(&patterns.raw),
    }
}

/// Files named on the command line, with directories expanded.
pub fn expand_arguments(arguments: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for argument in arguments {
        let argument = argument.strip_prefix("./").unwrap_or(argument);
        if is_directory(argument) {
            let dir = argument.trim_end_matches('/');
            out.extend(files(&Patterns::new(vec![format!("{dir}/**/*")])?)?);
        } else {
            out.push(argument.to_string());
        }
    }
    let mut seen = std::collections::HashSet::new();
    out.retain(|p| seen.insert(p.clone()));
    Ok(out)
}

/// The most of one file judgelint reads. A larger file is far past what a
/// model takes, and is reported as skipped.
pub const MAX_FILE_BYTES: u64 = 4 << 20;
/// A file with a NUL byte this near its start is binary.
const BINARY_PREFIX: usize = 8000;

/// A file's contents, as far as sending it goes.
pub enum Contents {
    Text(String),
    TooLarge,
    Binary,
}

/// The working directory, resolved, which every file sent must be inside.
fn root() -> &'static Path {
    static ROOT: OnceLock<PathBuf> = OnceLock::new();
    ROOT.get_or_init(|| fs::canonicalize(".").unwrap_or_else(|_| PathBuf::from(".")))
}

/// Reads a file to send to a model. Every file a model sees comes through
/// here: a regular file inside the working directory, not reached through a
/// link that leaves it, and, in a git repository, one git tracks or would
/// add. Anything else is an error that says why.
pub fn read_to_send(path: &str) -> Result<Contents> {
    let real = fs::canonicalize(path).with_context(|| format!("Couldn't read {path}"))?;
    // Unit tests work in temporary directories outside the project; the
    // end-to-end tests cover where a file may be.
    let root = if cfg!(test) { Path::new("/") } else { root() };
    let inside = real.strip_prefix(root).map_err(|_| anyhow!("{path} is outside the project"))?;
    if let Some(listed) = project_files().filter(|_| !cfg!(test)) {
        let inside = inside.to_string_lossy();
        if listed.binary_search_by(|p| p.as_str().cmp(&inside)).is_err() {
            bail!("{path} is ignored by git");
        }
    }
    let file = File::open(&real).with_context(|| format!("Couldn't read {path}"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        bail!("{path} isn't a regular file");
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Ok(Contents::TooLarge);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes).with_context(|| format!("Couldn't read {path}"))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Ok(Contents::TooLarge);
    }
    if bytes[..bytes.len().min(BINARY_PREFIX)].contains(&0) {
        return Ok(Contents::Binary);
    }
    Ok(Contents::Text(String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())))
}

/// A file's text, for a file that must be sendable.
pub fn read_text(path: &str) -> Result<String> {
    match read_to_send(path)? {
        Contents::Text(text) => Ok(text),
        Contents::TooLarge => bail!("{path} is over {} MB", MAX_FILE_BYTES >> 20),
        Contents::Binary => bail!("{path} is binary"),
    }
}

pub fn is_file(path: &str) -> bool {
    Path::new(path).is_file()
}

pub fn is_directory(path: &str) -> bool {
    Path::new(path).is_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(pattern: &str, path: &str) -> bool {
        Patterns::new(vec![pattern.to_string()]).unwrap().is_match(path)
    }

    #[test]
    fn patterns() {
        assert!(matches("app/**/*.rb", "app/a.rb"));
        assert!(matches("app/**/*.rb", "app/x/y/a.rb"));
        assert!(!matches("app/*.rb", "app/x/a.rb"));
        assert!(matches("**/*", "README"));
        assert!(matches("src/{one,two}/*.ts", "src/two/b.ts"));
        assert!(matches("vendor/**", "vendor/a/b.rb"));
        assert!(!matches("**/*", ".github/ci.yml"), "wildcards skip dotted names");
        assert!(matches(".github/*.yml", ".github/ci.yml"));
        assert!(matches("**/.hid/**/*.rb", ".hid/x/h.rb"));
    }
}
