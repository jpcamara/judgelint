//! Helpers for the unit tests.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::config::{self, OneOrMany};
use crate::project::{Holds, Project};
use crate::rule::{Frontmatter, Rule};

/// A new directory for one test, removed when it's dropped.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new() -> TempDir {
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let name = format!("judgelint-test-{}-{}", std::process::id(), COUNT.fetch_add(1, Ordering::Relaxed));
        let dir = std::env::temp_dir().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    /// The directory as a project, outside any git repository.
    pub fn project(&self) -> Project {
        Project::open(&self.0, Holds::WorkingTree).unwrap()
    }

    /// The absolute path of +relative+ in the directory.
    pub fn path(&self, relative: &str) -> String {
        self.0.join(relative).to_string_lossy().into_owned()
    }

    /// Runs git in the directory.
    pub fn git(&self, args: &[&str]) {
        let status = std::process::Command::new("git")
            .current_dir(&self.0)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(args)
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// Makes the directory a git repository and commits what's in it.
    pub fn commit_all(&self) {
        self.git(&["init", "-q", "-b", "main"]);
        self.git(&["add", "-A"]);
        self.git(&["commit", "-qm", "start"]);
    }

    /// Writes a file, and returns its absolute path.
    pub fn write(&self, relative: &str, content: &str) -> String {
        let path = self.path(relative);
        std::fs::create_dir_all(Path::new(&path).parent().unwrap()).unwrap();
        std::fs::write(&path, content).unwrap();
        path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A rule file's rule, as its frontmatter declares it: "Does this code
/// smell?" of app/**/*.rb unless +yaml+ says otherwise.
pub fn rule(id: &str, yaml: &str) -> Rule {
    let mut data: Frontmatter = config::parse_yaml(yaml, id).unwrap();
    if data.convention.is_none() {
        data.question = data.question.or(Some("Does this code smell?".into()));
    }
    data.paths = data.paths.or(Some(OneOrMany::One("app/**/*.rb".into())));
    data.message = data.message.or(Some("Smells.".into()));
    Rule::new(data, &format!(".judgelint/rules/{id}.md"), "", 0.7, None, None, Vec::new()).unwrap()
}

/// A spec's bullet as a rule, from README.md.
pub fn bullet(convention: &str) -> Rule {
    let data = Frontmatter { convention: Some(convention.into()), ..Frontmatter::default() };
    Rule::new(data, "README.md", "", 0.7, None, None, Vec::new()).unwrap()
}
