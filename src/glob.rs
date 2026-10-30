//! Patterns that rules match paths against. `*` stays within a directory,
//! `**/` spans any number of them, and `{a,b}` alternates. Wildcards don't
//! match names that start with a dot.

use anyhow::{Context, Result};
use globset::{Glob, GlobBuilder, GlobSet, GlobSetBuilder};

pub fn compile(pattern: &str) -> Result<Glob> {
    GlobBuilder::new(pattern).literal_separator(true).build().with_context(|| format!("Bad pattern {pattern}"))
}

/// A path with a part that starts with a dot.
pub fn hidden(path: &str) -> bool {
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
