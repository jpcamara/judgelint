//! What the model is shown: one file, or every file in a directory, with each
//! line numbered so a question can point at a range, followed by any context
//! files the rule names, which are there to read and never judged.
//!
//! A judgehint is a comment (#, //, --, /*, <!--, or ;) starting with
//! `judgehint:` that says why the code is the way it is. The model weighs it
//! for the window it falls in, or for the whole directory.

use std::fmt::Write;
use std::sync::{Arc, LazyLock};

use anyhow::Result;
use regex::Regex;
use serde_json::{Value, json};

use crate::glob;

static HINT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:#|//|--|/\*|<!--|;)\s*judgehint:").unwrap());

pub struct Source {
    pub path: Arc<str>,
    pub shown_as: Arc<str>,
    /// A directory's files; None for a single file.
    pub files: Option<Vec<String>>,
    /// The contents when they aren't on disk, like an example in a spec.
    pub text: Option<Arc<str>>,
    pub context: Arc<Vec<String>>,
    pub line_count: u32,
    /// The lines with a judgehint.
    pub hints: Vec<u32>,
    /// A directory with a file judgelint won't send, too large or leading
    /// outside the project, which can't be judged.
    pub unjudgeable: bool,
}

impl Source {
    pub fn file(path: &str, shown_as: Option<&str>, context: Arc<Vec<String>>, text: Option<Arc<str>>) -> Source {
        Source {
            path: Arc::from(path),
            shown_as: Arc::from(shown_as.unwrap_or(path)),
            files: None,
            text,
            context,
            line_count: 0,
            hints: Vec::new(),
            unjudgeable: false,
        }
    }

    /// A directory and its files, except the ignored and binary ones. One
    /// judgelint won't send, too large or leading outside the project, leaves
    /// the directory unjudgeable.
    pub fn directory(dir: &str, shown_as: Option<&str>, context: Arc<Vec<String>>) -> Result<Source> {
        let mut unjudgeable = false;
        let mut files = Vec::new();
        for file in glob::expand(&[format!("{dir}/**/*")])? {
            match glob::read_to_send(&file)? {
                glob::Contents::Text(_) => files.push(file),
                glob::Contents::Binary | glob::Contents::Ignored => {}
                glob::Contents::TooLarge | glob::Contents::Excluded(_) => unjudgeable = true,
            }
        }
        Ok(Source { files: Some(files), unjudgeable, ..Source::file(dir, shown_as, context, None) })
    }

    pub fn is_directory(&self) -> bool {
        self.files.is_some()
    }

    /// Counts the lines and finds the judgehints in the source's contents.
    pub fn scan(mut self, read: &[String]) -> Source {
        let mut count = 0u32;
        for line in read.iter().flat_map(|text| text.lines()) {
            count += 1;
            if line.contains("judgehint:") && HINT.is_match(line) {
                self.hints.push(count);
            }
        }
        self.line_count = count;
        self
    }

    /// The files whose contents make the state.
    pub fn file_list(&self) -> Vec<&str> {
        match &self.files {
            Some(files) => files.iter().map(String::as_str).collect(),
            None => vec![&*self.path],
        }
    }

    pub fn read_all(&self) -> Result<Vec<String>> {
        if let Some(text) = &self.text {
            return Ok(vec![text.to_string()]);
        }
        self.file_list().into_iter().map(glob::read_text).collect()
    }

    /// The state: the numbered text the model is shown, or {team_rules, file}
    /// with a spec's prose.
    pub fn state(&self, read: &[String], prose: Option<&str>) -> Result<Value> {
        let mut text = String::with_capacity(read.iter().map(|r| r.len() + r.len() / 4).sum::<usize>() + 64);
        if self.is_directory() {
            let _ = write!(text, "Directory: {}\n\n", self.shown_as);
            for (i, file) in self.file_list().into_iter().enumerate() {
                if i > 0 {
                    text.push('\n');
                }
                let _ = write!(text, "Path: {}\n\n", self.shown(file));
                numbered(&read[i], &mut text);
            }
        } else {
            let _ = write!(text, "Path: {}\n\n", self.shown_as);
            numbered(&read[0], &mut text);
        }
        if !self.context.is_empty() {
            text.push_str("\nContext, for reference only (not under review):\n\n");
            for (i, file) in self.context.iter().enumerate() {
                if i > 0 {
                    text.push('\n');
                }
                let _ = write!(text, "Path: {file}\n\n{}", glob::read_text(file)?);
            }
        }
        Ok(match prose {
            Some(prose) => json!({"team_rules": prose, "file": text}),
            None => Value::String(text),
        })
    }

    /// [first, last] ranges of +size+ lines that cover the file.
    pub fn windows(&self, size: u32) -> Vec<(u32, u32)> {
        (1..=self.line_count)
            .step_by(size as usize)
            .map(|first| (first, (first + size - 1).min(self.line_count)))
            .collect()
    }

    /// The directory's files as [path, the path the model sees].
    pub fn members(&self) -> Vec<(String, String)> {
        self.file_list().into_iter().map(|f| (f.to_string(), self.shown(f))).collect()
    }

    pub fn hinted(&self, first: u32, last: u32) -> bool {
        !self.hints.is_empty() && (self.is_directory() || self.hints.iter().any(|&l| l >= first && l <= last))
    }

    /// A file's path inside the directory, as the model sees it.
    fn shown(&self, file: &str) -> String {
        let inside = file.strip_prefix(&*self.path).and_then(|f| f.strip_prefix('/')).unwrap_or(file);
        format!("{}/{inside}", self.shown_as)
    }
}

fn numbered(contents: &str, out: &mut String) {
    for (number, line) in contents.lines().enumerate() {
        let _ = writeln!(out, "{}: {line}", number + 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;

    fn file(path: &str, shown_as: Option<&str>, text: &str) -> (Source, Vec<String>) {
        let read = vec![text.to_string()];
        (Source::file(path, shown_as, Arc::default(), None).scan(&read), read)
    }

    #[test]
    fn numbers_lines_and_covers_the_file_with_windows() {
        let (source, read) = file("a.rb", Some("shown.rb"), "one\ntwo\nthree");
        assert_eq!(source.state(&read, None).unwrap(), json!("Path: shown.rb\n\n1: one\n2: two\n3: three\n"));
        assert_eq!(source.windows(2), [(1, 2), (3, 3)]);
        assert_eq!(source.windows(40), [(1, 3)]);
    }

    #[test]
    fn judgehints_are_read_from_comments_only() {
        let (source, read) = file("app/a.rb", None, "x # judgehint: kept short\n");
        assert_eq!((source.line_count, source.hinted(1, 1)), (1, true));
        assert_eq!(source.state(&read, None).unwrap(), json!("Path: app/a.rb\n\n1: x # judgehint: kept short\n"));

        let (source, _) = file("app/a.rb", None, "raise \"judgehint: not a comment\"\n");
        assert!(!source.hinted(1, 1));
    }

    #[test]
    fn a_directory_is_its_files_then_the_context() {
        let dir = TempDir::new();
        dir.write("a/index.rb", "one\n");
        dir.write("a/helper.rb", "SMELL\n");
        let types = dir.write("types.rb", "Types = 1\n");
        let a = dir.path("a");
        let source = Source::directory(&a, None, Arc::new(vec![types.clone()])).unwrap();
        let read = source.read_all().unwrap();
        let expected = format!(
            "Directory: {a}\n\nPath: {a}/helper.rb\n\n1: SMELL\n\nPath: {a}/index.rb\n\n1: one\n\n\
             Context, for reference only (not under review):\n\nPath: {types}\n\nTypes = 1\n"
        );
        assert_eq!(source.scan(&read).state(&read, None).unwrap(), Value::String(expected));
    }
}
