//! The project: the directory judgelint runs in, the files in it a rule can
//! name, and the one way a file's contents are read to be sent. Paths are
//! relative to it.
//!
//! In a git repository the files are those git tracks or would add, or only
//! those it tracks when checking a pull request; elsewhere they're found on
//! disk. A walk doesn't follow links into directories under `**`, though a
//! literal directory in a pattern can be a link, and a link to a file is the
//! file.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{ErrorKind, Read};
use std::os::fd::OwnedFd;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};

use anyhow::{Context, Result, bail};
use ignore::{WalkBuilder, WalkState};
use rustix::fs::{Mode, OFlags};
use rustix::io::Errno;

use crate::changes::Commit;
use crate::git;
use crate::glob::{self, Patterns};

/// The most of one file judgelint reads. A larger file is far past what a
/// model takes, and is reported as skipped.
pub const MAX_FILE_BYTES: u64 = 4 << 20;
/// The most of a config judgelint reads.
const MAX_CONFIG_BYTES: u64 = 1 << 20;
/// A file with a NUL byte this near its start is binary.
const BINARY_PREFIX: usize = 8000;

/// Which of a repository's files the project holds.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Holds {
    /// The files git tracks or would add: the working tree as it is.
    WorkingTree,
    /// Only the files git tracks: a pull request's, without whatever else
    /// is in the checkout.
    Tracked,
}

/// A path found on disk, and whether it's a directory (or a link to one).
#[derive(Clone)]
pub struct Entry {
    pub path: String,
    pub dir: bool,
}

/// A file's contents, as far as sending it goes.
pub enum Contents {
    Text(String),
    TooLarge,
    Binary,
    /// Not one of the project's files: ignored by git, or untracked when
    /// only tracked files count.
    Ignored,
    /// A file judgelint won't send, and why: outside the project, or not a
    /// regular file.
    Excluded(String),
}

impl Contents {
    /// Why a file that isn't text can't be sent.
    pub fn why(&self, path: &str) -> String {
        match self {
            Contents::Text(_) => String::new(),
            Contents::TooLarge => format!("{path} is over {} MB", MAX_FILE_BYTES >> 20),
            Contents::Binary => format!("{path} is binary"),
            Contents::Ignored => format!("{path} isn't one of the project's files"),
            Contents::Excluded(why) => why.clone(),
        }
    }
}

/// Formats that are never code. Checking a change, a binary file in one is
/// left out; any other binary file can't be judged, since a NUL byte would
/// otherwise hide code.
const BINARY_FORMATS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tif", "tiff", "avif", "heic", "psd", "woff", "woff2", "ttf",
    "otf", "eot", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "jar", "pdf", "mp3", "mp4", "m4a", "wav", "ogg",
    "webm", "mov", "avi", "flac", "wasm", "so", "dylib", "dll", "exe", "o", "a", "class", "pyc", "sqlite",
];

pub fn binary_format(path: &str) -> bool {
    let extension = Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("");
    BINARY_FORMATS.iter().any(|format| extension.eq_ignore_ascii_case(format))
}

pub struct Project {
    /// The directory, resolved, which every file sent must be inside.
    root: PathBuf,
    dir: OwnedFd,
    /// In a git repository, the files git lists, sorted.
    listed: Option<Vec<String>>,
    /// Holding only tracked files, the commit they're from, and those the
    /// working tree has changed since, which are read as committed.
    committed: Option<(Commit, HashSet<String>)>,
    /// What's outside hidden directories, listed once and shared by the
    /// globs that look there, until it's released.
    tree: Mutex<Option<Arc<Vec<Entry>>>>,
}

impl Project {
    pub fn open(root: &Path, holds: Holds) -> Result<Project> {
        let root = fs::canonicalize(root).with_context(|| format!("Couldn't open {}", root.display()))?;
        let dir = rustix::fs::open(&root, OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC, Mode::empty())
            .with_context(|| format!("Couldn't open {}", root.display()))?;
        let listed = git::files(&root, holds == Holds::WorkingTree)?;
        let committed = match holds {
            Holds::Tracked if listed.is_some() => {
                let changed = git::run(&root, &["diff", "--name-only", "-z", "--no-renames", "--relative", "HEAD"])?;
                let changed = String::from_utf8_lossy(&changed)
                    .split('\0')
                    .filter(|p| !p.is_empty())
                    .map(str::to_string)
                    .collect();
                Some((Commit::new(&root, "HEAD")?, changed))
            }
            _ => None,
        };
        Ok(Project { root, dir, listed, committed, tree: Mutex::new(None) })
    }

    /// A path relative to the project, or an absolute one, on disk.
    fn at(&self, path: &str) -> PathBuf {
        self.root.join(path)
    }

    pub fn is_file(&self, path: &str) -> bool {
        self.at(path).is_file()
    }

    pub fn is_directory(&self, path: &str) -> bool {
        self.at(path).is_dir()
    }

    /// A directory, not a link to one.
    pub fn is_real_directory(&self, path: &str) -> bool {
        fs::symlink_metadata(self.at(path)).is_ok_and(|m| m.is_dir())
    }

    /// Lets go of the listing once the files are found.
    pub fn release(&self) {
        *self.tree.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    fn tree(&self) -> Arc<Vec<Entry>> {
        let mut tree = self.tree.lock().unwrap_or_else(|e| e.into_inner());
        tree.get_or_insert_with(|| Arc::new(walk(&self.root, true, None, false))).clone()
    }

    /// A directory the tree listing covers: relative, plain, and not reached
    /// through a link.
    fn in_tree(&self, base: &str) -> bool {
        if base.starts_with('/') {
            return false;
        }
        let mut path = self.root.clone();
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
    pub fn find(&self, pattern: &str) -> Result<Vec<Entry>> {
        let parts: Vec<&str> = pattern.split('/').collect();
        let literal = parts.iter().take_while(|p| !p.contains(['*', '?', '[', '{', '\\'])).count();
        if literal == parts.len() {
            return Ok(fs::metadata(self.at(pattern))
                .map(|m| Entry { path: pattern.to_string(), dir: m.is_dir() })
                .into_iter()
                .collect());
        }
        let base = parts[..literal].join("/");
        let rest = parts[literal..].join("/");
        let matcher = glob::compile(pattern)?.compile_matcher();
        let mut found: Vec<Entry> = if !glob::hidden(pattern) && self.in_tree(&base) {
            let prefix = if base.is_empty() { String::new() } else { format!("{base}/") };
            self.tree().iter().filter(|e| e.path.starts_with(&prefix) && matcher.is_match(&e.path)).cloned().collect()
        } else {
            // `base/.` walks through a link at the base.
            let root = if base.is_empty() { self.root.clone() } else { self.at(&format!("{base}/.")) };
            let recursive = rest.contains("**");
            let depth = (!recursive).then(|| parts.len() - literal);
            walk(&root, !glob::hidden(&rest), depth, !recursive)
                .into_iter()
                .map(|e| Entry {
                    path: if base.is_empty() { e.path } else { format!("{base}/{}", e.path) },
                    dir: e.dir,
                })
                .filter(|e| matcher.is_match(&e.path))
                .collect()
        };
        found.sort_unstable_by(|a, b| a.path.cmp(&b.path));
        Ok(found)
    }

    /// The files the patterns match, sorted.
    pub fn expand(&self, patterns: &[String]) -> Result<Vec<String>> {
        let mut files = Vec::new();
        for pattern in patterns {
            files.extend(self.find(pattern)?.into_iter().filter(|e| !e.dir).map(|e| e.path));
        }
        files.sort_unstable();
        files.dedup();
        Ok(files)
    }

    /// The directories a pattern matches, sorted.
    pub fn directories(&self, pattern: &str) -> Result<Vec<String>> {
        Ok(self.find(pattern)?.into_iter().filter(|e| e.dir).map(|e| e.path).collect())
    }

    /// The files to check: in a git repository, those it lists; elsewhere,
    /// every file the patterns match.
    pub fn files(&self, patterns: &Patterns) -> Result<Vec<String>> {
        match &self.listed {
            Some(listed) => Ok(listed.iter().filter(|p| patterns.is_match(p) && self.is_file(p)).cloned().collect()),
            None => self.expand(&patterns.raw),
        }
    }

    /// Files named on the command line, with directories expanded.
    pub fn expand_arguments(&self, arguments: &[String]) -> Result<Vec<String>> {
        let mut out: Vec<String> = Vec::new();
        for argument in arguments {
            let argument = argument.strip_prefix("./").unwrap_or(argument);
            if self.is_directory(argument) {
                let dir = argument.trim_end_matches('/');
                out.extend(self.files(&Patterns::new(vec![format!("{dir}/**/*")])?)?);
            } else {
                out.push(argument.to_string());
            }
        }
        let mut seen = std::collections::HashSet::new();
        out.retain(|p| seen.insert(p.clone()));
        Ok(out)
    }

    /// Opens a file in the project, without waiting on one that isn't a
    /// regular file. It fails with ELOOP when any part of the path is a link,
    /// so where it leads can't change between a check and the open.
    fn open_without_links(&self, path: &Path) -> rustix::io::Result<File> {
        let flags = OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC;
        #[cfg(target_vendor = "apple")]
        let opened = rustix::fs::openat(&self.dir, path, flags | OFlags::NOFOLLOW_ANY, Mode::empty());
        #[cfg(target_os = "linux")]
        let opened = {
            use rustix::fs::ResolveFlags;
            let resolve = ResolveFlags::BENEATH | ResolveFlags::NO_SYMLINKS;
            match rustix::fs::openat2(&self.dir, path, flags, Mode::empty(), resolve) {
                // A kernel before 5.6, or a sandbox that blocks openat2.
                Err(Errno::NOSYS | Errno::PERM) => open_part_by_part(&self.dir, path, flags),
                opened => opened,
            }
        };
        #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
        let opened = open_part_by_part(&self.dir, path, flags);
        opened.map(File::from)
    }

    /// Opens a file to send, with its path relative to the project.
    fn open_inside(&self, path: &str) -> Result<Opened> {
        let couldnt = || format!("Couldn't read {path}");
        let relative = Path::new(path.strip_prefix("./").unwrap_or(path));
        if relative.components().all(|c| matches!(c, Component::Normal(_))) {
            match self.open_without_links(relative) {
                Ok(file) => return Ok(Opened::File(file, relative.to_string_lossy().into_owned())),
                Err(Errno::LOOP) => {}
                Err(Errno::NOENT | Errno::NOTDIR) => return Ok(Opened::Missing),
                Err(e) => return Err(std::io::Error::from(e)).with_context(couldnt),
            }
        }
        // A link, or a path that leaves and may come back: where it leads,
        // opened without links so it can't lead anywhere else by then.
        let real = match fs::canonicalize(self.at(path)) {
            Ok(real) => real,
            Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => return Ok(Opened::Missing),
            Err(e) => return Err(e).with_context(couldnt),
        };
        let Ok(inside) = real.strip_prefix(&self.root) else { return Ok(Opened::Outside) };
        let file = self.open_without_links(inside).map_err(std::io::Error::from).with_context(couldnt)?;
        Ok(Opened::File(file, inside.to_string_lossy().into_owned()))
    }

    /// A file the working tree changed since the pull request's commit, as
    /// committed: what judgelint judges is the pull request, not what a step
    /// before it wrote over it.
    fn as_committed(&self, path: &str, inside: &str) -> Option<Result<Contents>> {
        let (commit, _) = self.committed.as_ref().filter(|(_, changed)| changed.contains(inside))?;
        Some((|| {
            Ok(match commit.size(inside)? {
                None => Contents::Excluded(format!("{path} isn't a file in the pull request's commit")),
                Some(size) if size > MAX_FILE_BYTES => Contents::TooLarge,
                Some(_) => text_or_binary(commit.read(inside)?.unwrap_or_default()),
            })
        })())
    }

    /// Reads a file to send to a model. Every file a model sees comes through
    /// here: a regular file inside the project, not reached through a link
    /// that leaves it, and, in a git repository, one git lists. Anything else
    /// is Excluded, with why; a file that can't be read is an error.
    pub fn read_to_send(&self, path: &str) -> Result<Contents> {
        let excluded = |why: &str| Ok(Contents::Excluded(format!("{path} {why}")));
        if let Some(committed) = self.as_committed(path, path.strip_prefix("./").unwrap_or(path)) {
            return committed;
        }
        let (file, inside) = match self.open_inside(path)? {
            Opened::File(file, inside) => (file, inside),
            Opened::Outside => return excluded("is outside the project"),
            Opened::Missing => return excluded("doesn't lead to a file"),
        };
        if let Some(listed) = &self.listed
            && listed.binary_search_by(|p| p.as_str().cmp(&inside)).is_err()
        {
            return Ok(Contents::Ignored);
        }
        if let Some(committed) = self.as_committed(path, &inside) {
            return committed;
        }
        let bytes = match load(file, MAX_FILE_BYTES).with_context(|| format!("Couldn't read {path}"))? {
            Loaded::Bytes(bytes) => bytes,
            Loaded::TooLarge => return Ok(Contents::TooLarge),
            Loaded::NotRegular => return excluded("isn't a regular file"),
        };
        Ok(text_or_binary(bytes))
    }

    /// A file's text, for a file that must be sendable.
    pub fn read_text(&self, path: &str) -> Result<String> {
        match self.read_to_send(path)? {
            Contents::Text(text) => Ok(text),
            other => bail!("{}", other.why(path)),
        }
    }

    /// The project's config file, or None when there's none: like a file to
    /// send, it must be a regular file inside the project, and small.
    pub fn read_config(&self, path: &str) -> Result<Option<String>> {
        if fs::symlink_metadata(self.at(path)).is_err() {
            return Ok(None);
        }
        let file = match self.open_inside(path)? {
            Opened::File(file, _) => file,
            Opened::Outside => bail!("{path} is outside the project"),
            Opened::Missing => bail!("{path} doesn't lead to a file"),
        };
        config_text(path, file).map(Some)
    }
}

/// A config named on the command line, wherever it is: whoever runs
/// judgelint chose it. It must still be a regular file, and small.
pub fn read_named_config(path: &str) -> Result<String> {
    let file = File::open(path).with_context(|| format!("No config file at {path}"))?;
    config_text(path, file)
}

fn config_text(path: &str, file: File) -> Result<String> {
    match load(file, MAX_CONFIG_BYTES).with_context(|| format!("Couldn't read {path}"))? {
        Loaded::Bytes(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
        Loaded::TooLarge => bail!("{path} is over {} KB", MAX_CONFIG_BYTES >> 10),
        Loaded::NotRegular => bail!("{path} isn't a regular file"),
    }
}

fn text_or_binary(bytes: Vec<u8>) -> Contents {
    if bytes[..bytes.len().min(BINARY_PREFIX)].contains(&0) {
        return Contents::Binary;
    }
    Contents::Text(String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()))
}

/// Where a path leads.
enum Opened {
    File(File, String),
    Outside,
    /// Nothing, or a link to nothing.
    Missing,
}

enum Loaded {
    Bytes(Vec<u8>),
    TooLarge,
    /// A pipe, a device, a directory: anything but a regular file.
    NotRegular,
}

/// A regular file's bytes, up to +limit+.
fn load(file: File, limit: u64) -> std::io::Result<Loaded> {
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Ok(Loaded::NotRegular);
    }
    if metadata.len() > limit {
        return Ok(Loaded::TooLarge);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(limit + 1).read_to_end(&mut bytes)?;
    Ok(if bytes.len() as u64 > limit { Loaded::TooLarge } else { Loaded::Bytes(bytes) })
}

/// Opens each directory down the path, then the file, refusing a link at any
/// step: what openat2 does in one call where there is one.
#[cfg(not(target_vendor = "apple"))]
fn open_part_by_part(dir: &OwnedFd, path: &Path, flags: OFlags) -> rustix::io::Result<OwnedFd> {
    let parts: Vec<&std::ffi::OsStr> = path.iter().collect();
    let Some((file, dirs)) = parts.split_last() else { return Err(Errno::NOENT) };
    let directory = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut current: Option<OwnedFd> = None;
    for part in dirs {
        let next = rustix::fs::openat(current.as_ref().unwrap_or(dir), *part, directory, Mode::empty())?;
        current = Some(next);
    }
    rustix::fs::openat(current.as_ref().unwrap_or(dir), *file, flags | OFlags::NOFOLLOW, Mode::empty())
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;

    fn text(project: &Project, path: &str) -> Option<String> {
        match project.read_to_send(path).unwrap() {
            Contents::Text(text) => Some(text),
            _ => None,
        }
    }

    #[test]
    fn reads_only_regular_files_inside_the_project() {
        let outside = TempDir::new();
        let secret = outside.write("secret.txt", "OUTSIDE\n");
        let dir = TempDir::new();
        dir.write("app/a.rb", "inside\n");
        std::os::unix::fs::symlink("a.rb", dir.path("app/same.rb")).unwrap();
        std::os::unix::fs::symlink(&secret, dir.path("app/out.rb")).unwrap();
        std::os::unix::fs::symlink(outside.path(""), dir.path("linked")).unwrap();
        let project = dir.project();

        assert_eq!(text(&project, "app/a.rb").as_deref(), Some("inside\n"));
        assert_eq!(text(&project, "./app/same.rb").as_deref(), Some("inside\n"), "a link within is followed");
        for out in ["app/out.rb", "linked/secret.txt", "../secret.txt", &secret] {
            assert!(matches!(project.read_to_send(out), Ok(Contents::Excluded(_)) | Err(_)), "{out}");
        }
        assert!(matches!(project.read_to_send("app").unwrap(), Contents::Excluded(_)), "a directory");
    }

    #[test]
    fn binary_and_large_files() {
        let dir = TempDir::new();
        std::fs::write(dir.path("blob"), b"x\0y").unwrap();
        std::fs::write(dir.path("big"), vec![b'x'; MAX_FILE_BYTES as usize + 1]).unwrap();
        let project = dir.project();
        assert!(matches!(project.read_to_send("blob").unwrap(), Contents::Binary));
        assert!(matches!(project.read_to_send("big").unwrap(), Contents::TooLarge));
    }

    #[test]
    fn a_config_must_be_a_small_regular_file_inside() {
        let outside = TempDir::new();
        let secret = outside.write("secret.yml", "token: OUTSIDE\n");
        let dir = TempDir::new();
        let project = dir.project();
        assert_eq!(project.read_config(".judgelint.yml").unwrap(), None);
        std::os::unix::fs::symlink(&secret, dir.path(".judgelint.yml")).unwrap();
        let error = project.read_config(".judgelint.yml").unwrap_err().to_string();
        assert!(error.contains("outside the project") && !error.contains("OUTSIDE"), "{error}");
    }

    #[test]
    fn a_pull_request_is_read_as_committed() {
        let dir = TempDir::new();
        dir.write("app/a.rb", "committed\n");
        dir.commit_all();
        dir.write("app/a.rb", "written over\n");
        dir.write("app/new.rb", "untracked\n");
        let pull_request = Project::open(Path::new(&dir.path("")), Holds::Tracked).unwrap();
        assert_eq!(text(&pull_request, "app/a.rb").as_deref(), Some("committed\n"));
        assert!(matches!(pull_request.read_to_send("app/new.rb").unwrap(), Contents::Ignored));
        assert_eq!(text(&dir.project(), "app/a.rb").as_deref(), Some("written over\n"), "the working tree otherwise");
        assert_eq!(text(&dir.project(), "app/new.rb").as_deref(), Some("untracked\n"));
    }

    #[test]
    fn a_path_to_nothing_doesnt_lead_to_a_file() {
        let dir = TempDir::new();
        std::os::unix::fs::symlink("missing.rb", dir.path("link.rb")).unwrap();
        let project = dir.project();
        for path in ["link.rb", "missing.rb", "no/such/dir.rb"] {
            let Contents::Excluded(why) = project.read_to_send(path).unwrap() else { panic!("{path}") };
            assert_eq!(why, format!("{path} doesn't lead to a file"));
        }
    }
}
