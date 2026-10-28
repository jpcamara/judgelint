//! One convention, asked of a file as a single yes/no question or choice.
//! Rules come from specs (see spec.rs): a bullet in a CONVENTIONS.md or
//! README, or a file in .judgelint/rules with a question in its frontmatter.
//!
//! +scope+ window asks about each range of lines, so a finding says where it
//! is; file asks once about the whole file; directory asks once about each
//! directory its paths match, with all of the directory's files. A
//! fail_when: no rule is about the whole file by default. +context+ globs name
//! files the model reads alongside, which are never judged themselves.

use std::path::Path;
use std::sync::{Arc, LazyLock};

use anyhow::{Result, bail};
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use crate::config::{OneOrMany, list};
use crate::glob::{self, Patterns};
use crate::source::Source;

#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    Window,
    File,
    Directory,
}

/// The older name for a spec's scope.
#[derive(Deserialize, Clone, Copy, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Cohort {
    ByFile,
    ByDirectory,
}

#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
}

/// A spec's or rule file's frontmatter, and what a spec's bullet adds.
#[derive(Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub struct Frontmatter {
    pub id: Option<String>,
    pub question: Option<String>,
    pub convention: Option<String>,
    pub yes_means: Option<String>,
    pub no_means: Option<String>,
    /// yes or no; YAML may read either as a boolean.
    pub fail_when: Option<Value>,
    pub scope: Option<Scope>,
    pub cohort: Option<Cohort>,
    pub paths: Option<OneOrMany<String>>,
    pub excludes: Option<OneOrMany<String>>,
    pub context: Option<OneOrMany<String>>,
    pub severity: Option<Severity>,
    pub threshold: Option<f64>,
    pub message: Option<String>,
    #[serde(rename = "type")]
    pub _kind: Option<serde::de::IgnoredAny>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Expected {
    Pass,
    Fail,
}

impl Expected {
    pub fn name(self) -> &'static str {
        match self {
            Expected::Pass => "pass",
            Expected::Fail => "fail",
        }
    }
}

/// A Bad or Good code block under a spec's bullet. `judgelint test` judges it
/// like a file in the rule's fail/ or pass/ examples.
#[derive(Clone, Debug)]
pub struct InlineExample {
    pub expected: Expected,
    pub code: String,
    pub line: usize,
    pub language: String,
}

impl InlineExample {
    /// The file name the model sees.
    pub fn name(&self) -> String {
        if self.language.is_empty() { "example".into() } else { format!("example.{}", self.language) }
    }
}

pub struct Rule {
    pub id: String,
    pub question: Option<String>,
    pub convention: Option<String>,
    pub yes_means: Option<String>,
    pub no_means: Option<String>,
    pub fail_when_yes: bool,
    pub scope: Scope,
    pub paths: Patterns,
    pub excludes: Patterns,
    pub context: Vec<String>,
    pub severity: Severity,
    pub threshold: f64,
    pub message: String,
    pub source: String,
    pub examples_dir: String,
    pub prose: Option<Arc<str>>,
    pub inline_examples: Vec<InlineExample>,
    /// The id as a question key: letters, digits and underscores.
    pub question_key: String,
}

/// The text, or None when it's blank.
fn text(value: Option<String>) -> Option<String> {
    value.map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

static PARAGRAPH_BREAK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\n\s*\n").unwrap());
static LINE_BREAK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\n\s*").unwrap());

fn first_paragraph(body: &str) -> Option<String> {
    PARAGRAPH_BREAK
        .split(body)
        .map(str::trim)
        .find(|part| !part.is_empty() && !part.starts_with('#'))
        .map(|part| LINE_BREAK.replace_all(part, " ").into_owned())
}

impl Rule {
    /// A rule is a question asked exactly as written, or a convention (a
    /// spec's bullet) asked whether the code breaks it. +prose+ is a spec's
    /// body, which the model reads alongside the file.
    pub fn new(
        data: Frontmatter,
        source: &str,
        body: &str,
        default_threshold: f64,
        examples_dir: Option<String>,
        prose: Option<Arc<str>>,
        inline_examples: Vec<InlineExample>,
    ) -> Result<Rule> {
        let stem = || Path::new(source).file_stem().map_or(source.to_string(), |s| s.to_string_lossy().into_owned());
        let id = data.id.filter(|id| !id.is_empty()).unwrap_or_else(stem);
        let question = text(data.question);
        let convention = text(data.convention);
        if question.is_none() && convention.is_none() {
            bail!("{source}: a rule needs a question");
        }
        let fail_when_yes = match &data.fail_when {
            None | Some(Value::Bool(true)) => true,
            Some(Value::Bool(false)) => false,
            Some(Value::String(word)) if word == "yes" || word == "no" => word == "yes",
            Some(other) => bail!("{source}: fail_when is yes or no, not {other}"),
        };
        let scope = data
            .scope
            .or(data.cohort.map(|c| match c {
                Cohort::ByFile => Scope::File,
                Cohort::ByDirectory => Scope::Directory,
            }))
            .unwrap_or(if fail_when_yes { Scope::Window } else { Scope::File });
        let threshold = data.threshold.unwrap_or(default_threshold);
        if !(threshold > 0.0 && threshold <= 1.0) {
            bail!("{source}: threshold must be between 0 and 1");
        }
        let paths = data.paths.map_or_else(|| vec!["**/*".to_string()], OneOrMany::into_vec);
        let message = text(data.message)
            .or_else(|| first_paragraph(body))
            .or_else(|| question.clone())
            .or_else(|| convention.clone())
            .unwrap_or_default();
        let question_key = id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect();
        Ok(Rule {
            question_key,
            question,
            convention,
            yes_means: text(data.yes_means),
            no_means: text(data.no_means),
            fail_when_yes,
            scope,
            paths: Patterns::new(paths)?,
            excludes: Patterns::new(list(data.excludes))?,
            context: list(data.context),
            severity: data.severity.unwrap_or(Severity::Error),
            threshold,
            message,
            examples_dir: examples_dir.unwrap_or_else(|| source.strip_suffix(".md").unwrap_or(source).to_string()),
            source: source.to_string(),
            prose,
            inline_examples,
            id,
        })
    }

    pub fn severity(&self) -> &'static str {
        match self.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        }
    }

    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }

    pub fn applies_to(&self, path: &str) -> bool {
        self.paths.is_match(path) && !self.excludes.is_match(path)
    }

    pub fn is_window(&self) -> bool {
        self.scope == Scope::Window
    }

    pub fn is_directory(&self) -> bool {
        self.scope == Scope::Directory
    }

    /// The directories a directory rule governs.
    pub fn directories(&self) -> Result<Vec<String>> {
        let mut dirs = Vec::new();
        for pattern in &self.paths.raw {
            dirs.extend(glob::directories(pattern)?.into_iter().filter(|d| self.applies_to(d)));
        }
        dirs.sort_unstable();
        dirs.dedup();
        Ok(dirs)
    }

    /// The ranges to ask about: windows of +size+ lines, or the whole file.
    pub fn ranges(&self, source: &Source, size: u32) -> Vec<(u32, u32)> {
        if self.is_window() {
            source.windows(size)
        } else if source.line_count == 0 {
            Vec::new()
        } else {
            vec![(1, source.line_count)]
        }
    }

    pub fn violation_probability(&self, yes: f64) -> f64 {
        if self.fail_when_yes { yes } else { 1.0 - yes }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec;

    fn rule_file(id: &str, content: &str) -> Result<Vec<Rule>> {
        spec::parse(&format!(".judgelint/rules/{id}.md"), content, 0.7, true)
    }

    #[test]
    fn reads_frontmatter_and_uses_the_body_for_the_message() {
        let content = "\
---
question: Does this code swallow an exception?
yes_means: A rescue drops the error.
no_means: Errors are logged or re-raised.
paths: \"app/**/*.rb\"
excludes: [\"app/legacy/**\"]
severity: warning
threshold: 0.8
---
# Heading

Swallowed exceptions
hide bugs.
";
        let rule = rule_file("no-silent-rescue", content).unwrap().remove(0);
        assert_eq!(rule.id, "no-silent-rescue");
        assert_eq!(rule.question_key, "no_silent_rescue");
        assert_eq!(rule.yes_means.as_deref(), Some("A rescue drops the error."));
        assert_eq!(rule.paths.raw, ["app/**/*.rb"]);
        assert_eq!(rule.severity(), "warning");
        assert_eq!(rule.threshold, 0.8);
        assert_eq!(rule.message, "Swallowed exceptions hide bugs.");
        assert!(rule.applies_to("app/services/foo.rb"));
        assert!(rule.applies_to("app/foo.rb"));
        assert!(!rule.applies_to("app/legacy/old.rb"));
        assert!(!rule.applies_to("lib/foo.rb"));
    }

    #[test]
    fn bare_yes_and_no_from_yaml_still_mean_answers() {
        let rule = rule_file("validates", "---\nquestion: Does this validate input first?\nfail_when: no\n---\n")
            .unwrap()
            .remove(0);
        assert!(!rule.fail_when_yes);
        assert!((rule.violation_probability(0.2) - 0.8).abs() < 1e-9);
        assert_eq!(rule.threshold, 0.7);
    }

    #[test]
    fn rejects_unknown_keys_and_missing_questions() {
        assert!(rule_file("bad", "---\nquestion: Q?\nyes: something\n---\n").is_err());
        let error = rule_file("bad", "---\npaths: [x]\n---\n").err().unwrap();
        assert!(error.to_string().contains("needs a question"), "{error}");
    }

    #[test]
    fn rejects_bad_thresholds() {
        for threshold in ["high", "1.5"] {
            let content = format!("---\nquestion: Does this code smell?\nthreshold: {threshold}\n---\n");
            assert!(rule_file("smell", &content).is_err(), "{threshold}");
        }
    }
}
