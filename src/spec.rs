//! Finds rules where a team already writes its conventions: a
//! CONVENTIONS.md or *.judgelint.md, or a README whose frontmatter says which
//! files it governs, with one convention per top-level bullet.
//!
//! A CONVENTIONS.md or *.judgelint.md needs no frontmatter. Without paths:,
//! it governs the files under its own directory, except Markdown and
//! lockfiles. A README is a spec only when it has paths:. Each bullet becomes
//! a rule, with an id from its lead words. Indented `violation:` and
//! `compliant:` lines under a bullet say what each looks like, and code
//! blocks under a "Bad:" or "Good:" line are examples for `judgelint test`.
//! Files in .judgelint/rules/ work the same way, and one there with a
//! question: in its frontmatter is a single rule asked exactly that way.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, LazyLock};

use anyhow::{Result, bail};
use regex::Regex;
use serde::Deserialize;
use serde::de::IgnoredAny;

use crate::config::{self, OneOrMany, RULES_DIR};
use crate::glob::Patterns;
use crate::project::Project;
use crate::rule::{Expected, Frontmatter, InlineExample, Rule, Severity};

const PATTERNS: [&str; 3] = ["**/README.md", "**/CONVENTIONS.md", "**/*.judgelint.md"];
/// What a spec without paths: leaves out of its directory.
const UNJUDGED: [&str; 4] = ["**/*.md", "**/*.lock", "**/package-lock.json", "**/pnpm-lock.yaml"];

static FRONTMATTER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z").unwrap());
static BULLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\A(?:[-*+]|[0-9]+[.)])\s+(\S.*)\z").unwrap());
static CRITERION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\A(violation|compliant):\s*(\S.*)\z").unwrap());
static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\A[*_]*(bad|good)[*_]*:?[*_]*\z").unwrap());
static LEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\A\*\*(.+?)\*\*").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
static SENTENCE_END: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[.!?:](?:\s|\z)").unwrap());
static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new("[a-z0-9]+").unwrap());
static ADVISORY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(should|prefer|ideally|consider)\b").unwrap());
static FIRM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(must|never|always)\b").unwrap());

/// Every rule: the rule files in .judgelint/rules, then the specs.
pub fn discover(project: &Project, default_threshold: f64, ignore: &Patterns) -> Result<Vec<Rule>> {
    let rule_files = Patterns::new(vec![format!("{RULES_DIR}/*.md")])?;
    let spec_files = Patterns::new(PATTERNS.map(String::from).to_vec())?;
    let rule_paths = project.expand(&rule_files.raw)?;
    let spec_paths = project.files(&spec_files)?;
    let read = |path: &str| project.read_text(path);
    let mut found = Vec::new();
    for path in rule_paths {
        found.extend(parse(&path, &read(&path)?, default_threshold, true)?);
    }
    let own = format!("{RULES_DIR}/");
    for path in spec_paths {
        if !path.starts_with(&own) && !ignore.is_match(&path) {
            found.extend(parse(&path, &read(&path)?, default_threshold, false)?);
        }
    }
    if found.is_empty() {
        bail!("No rules: write your conventions as bullets in CONVENTIONS.md, or run `judgelint init`");
    }
    let mut seen: HashMap<&str, &str> = HashMap::new();
    for rule in &found {
        if let Some(other) = seen.insert(&rule.question_key, &rule.id) {
            bail!("Rule ids collide: {other}, {}", rule.id);
        }
    }
    Ok(found)
}

/// The rules in a rule file, which must have frontmatter, or a spec, from
/// its contents. A README without paths: in its frontmatter isn't a spec.
pub fn parse(path: &str, content: &str, default_threshold: f64, rule_file: bool) -> Result<Vec<Rule>> {
    let matched = FRONTMATTER.captures(content);
    let named_spec = !rule_file && Path::new(path).file_name().is_some_and(|n| n != "README.md");
    let (data, body): (Frontmatter, &str) = match &matched {
        Some(m) if !(rule_file || named_spec || is_spec(&m[1], path)?) => return Ok(Vec::new()),
        Some(m) => (config::parse_yaml(&m[1], path)?, m.get(2).map_or("", |b| b.as_str())),
        None if rule_file => bail!("{path}: rules start with a --- frontmatter block"),
        None if named_spec => (Frontmatter::default(), content),
        None => return Ok(Vec::new()),
    };
    if data.question.is_some() {
        return Ok(vec![Rule::new(data, path, body.trim(), default_threshold, None, None, Vec::new())?]);
    }
    if !(rule_file || named_spec || data.paths.is_some()) {
        return Ok(Vec::new());
    }
    let mut shared = Frontmatter {
        paths: data.paths,
        excludes: data.excludes,
        context: data.context,
        severity: data.severity,
        threshold: data.threshold,
        scope: data.scope,
        cohort: data.cohort,
        ..Frontmatter::default()
    };
    if shared.paths.is_none() && !rule_file {
        let dir = Path::new(path).parent().map(|d| d.to_string_lossy().into_owned()).filter(|d| !d.is_empty());
        shared.paths = Some(OneOrMany::One(dir.map_or("**/*".into(), |d| format!("{d}/**/*"))));
        let mut excludes = config::list(shared.excludes.take());
        excludes.extend(UNJUDGED.map(String::from));
        shared.excludes = Some(OneOrMany::Many(excludes));
    }
    let offset = content[..content.len() - body.len()].matches('\n').count();
    let found = bullets(body, offset);
    if found.is_empty() && rule_file {
        bail!("{path}: a rule needs a question, or bullets to turn into rules");
    }
    let prose: Arc<str> = Arc::from(body.trim());
    let spec = name(path);
    let mut ids: Vec<String> = Vec::new();
    let mut rules = Vec::with_capacity(found.len());
    for bullet in found {
        let id = unique(&format!("{spec}/{}", slug(&bullet.text)), &mut ids);
        let data = Frontmatter {
            id: Some(id.clone()),
            convention: Some(plain(&bullet.text)),
            message: Some(lead(&bullet.text)),
            yes_means: bullet.violation.as_deref().map(plain),
            no_means: bullet.compliant.as_deref().map(plain),
            severity: shared.severity.or(Some(severity(&bullet.text))),
            ..shared.clone()
        };
        let examples_dir = format!(".judgelint/examples/{id}");
        rules.push(Rule::new(
            data,
            path,
            "",
            default_threshold,
            Some(examples_dir),
            Some(prose.clone()),
            bullet.examples,
        )?);
    }
    Ok(rules)
}

/// Whether a README's frontmatter has paths: or a question:. It's read
/// loosely first, so a README with other tools' keys (title:) isn't an error.
fn is_spec(yaml: &str, path: &str) -> Result<bool> {
    #[derive(Deserialize, Default)]
    struct Keys {
        paths: Option<IgnoredAny>,
        question: Option<IgnoredAny>,
    }
    let keys: Keys = config::parse_yaml(yaml, path)?;
    Ok(keys.paths.is_some() || keys.question.is_some())
}

#[derive(Default)]
pub struct Bullet {
    pub text: String,
    pub violation: Option<String>,
    pub compliant: Option<String>,
    pub examples: Vec<InlineExample>,
}

impl Bullet {
    fn criterion(&mut self, name: &str) -> &mut Option<String> {
        if name == "violation" { &mut self.violation } else { &mut self.compliant }
    }
}

/// The top-level bullets of the body, outside code fences: the text with its
/// continuation lines and nested bullets, any indented violation: or
/// compliant: lines, and the code blocks under a "Bad:" or "Good:" line.
/// +offset+ is the number of lines before the body, so an example's line
/// number is the spec file's.
pub fn bullets(body: &str, offset: usize) -> Vec<Bullet> {
    let mut found = Vec::new();
    let mut current: Option<Bullet> = None;
    let mut criterion: Option<String> = None;
    let mut label: Option<Expected> = None;
    let mut fenced = false;
    let mut indent = 0usize;
    // An example's code, its first line and its language.
    let mut code: Option<(String, usize, String)> = None;
    for (number, line) in body.lines().enumerate().map(|(i, l)| (offset + i + 1, l)) {
        let trimmed = line.trim();
        if line.trim_start().starts_with("```") {
            if fenced {
                if let (Some((text, start, language)), Some(bullet)) = (code.take(), current.as_mut()) {
                    let expected = label.unwrap_or(Expected::Pass);
                    bullet.examples.push(InlineExample { expected, code: text, line: start, language });
                }
            } else {
                indent = line.len() - line.trim_start().len();
                if current.is_some() && label.is_some() && indent > 0 {
                    let language = trimmed.trim_start_matches('`').split_whitespace().next().unwrap_or("");
                    code = Some((String::new(), number + 1, language.to_string()));
                }
            }
            fenced = !fenced;
            continue;
        }
        if fenced {
            if let Some((text, _, _)) = code.as_mut() {
                let cut = line.bytes().take(indent).take_while(|b| *b == b' ' || *b == b'\t').count();
                text.push_str(&line[cut..]);
                text.push('\n');
            }
            continue;
        }
        if let Some(bullet) = BULLET.captures(line) {
            found.extend(current.take());
            current = Some(Bullet { text: bullet[1].to_string(), ..Bullet::default() });
            criterion = None;
            label = None;
        } else if let Some(bullet) = current.as_mut()
            && (line.starts_with(' ') || line.starts_with('\t'))
            && !trimmed.is_empty()
        {
            let text = BULLET.captures(trimmed).map_or(trimmed.to_string(), |n| n[1].to_string());
            if let Some(named) = CRITERION.captures(&text) {
                let name = named[1].to_lowercase();
                *bullet.criterion(&name) = Some(named[2].to_string());
                criterion = Some(name);
            } else if let Some(labeled) = LABEL.captures(&text) {
                label = Some(if labeled[1].eq_ignore_ascii_case("bad") { Expected::Fail } else { Expected::Pass });
                criterion = None;
            } else if label.is_some() {
                // Commentary on the examples isn't part of the rule.
            } else if let Some(name) = &criterion {
                let slot = bullet.criterion(name);
                *slot = Some(format!("{} {text}", slot.as_deref().unwrap_or("")));
            } else {
                bullet.text.push(' ');
                bullet.text.push_str(&text);
            }
        } else if current.is_some() && !trimmed.is_empty() {
            found.extend(current.take());
        }
    }
    found.extend(current);
    found
}

/// The bullet with its markdown emphasis removed: what the model is asked about.
pub fn plain(text: &str) -> String {
    SPACES.replace_all(&text.replace("**", ""), " ").trim().to_string()
}

/// The bold lead, or the first sentence: what judgelint prints for a finding.
pub fn lead(text: &str) -> String {
    let sentence = LEAD.captures(text).map_or_else(|| plain(text), |bold| bold[1].to_string());
    let end = SENTENCE_END.find(&sentence).map_or(sentence.len(), |m| m.start());
    let sentence = sentence[..end].trim();
    format!("{}.", sentence.strip_suffix(['.', '!', '?', ':']).unwrap_or(sentence))
}

pub fn slug(text: &str) -> String {
    let lowered = lead(text).to_lowercase();
    let words: Vec<&str> = WORD.find_iter(&lowered).take(6).map(|m| m.as_str()).collect();
    if words.is_empty() { "rule".into() } else { words.join("-") }
}

fn unique(id: &str, taken: &mut Vec<String>) -> String {
    let mut candidate = id.to_string();
    let mut number = 1;
    while taken.contains(&candidate) {
        number += 1;
        candidate = format!("{id}-{number}");
    }
    taken.push(candidate.clone());
    candidate
}

/// Spec names: a README's or CONVENTIONS.md's directory, or a file's stem.
fn name(path: &str) -> String {
    let file = Path::new(path);
    let base = file.file_name().map_or(path.into(), |n| n.to_string_lossy().into_owned());
    if base == "README.md" || base == "CONVENTIONS.md" {
        let dir = file.parent().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
        return if dir.is_empty() { "root".into() } else { dir };
    }
    let stem = base.strip_suffix(".md").unwrap_or(&base);
    stem.strip_suffix(".judgelint").unwrap_or(stem).to_string()
}

/// Praxis's reading: "should" and "prefer" are advice, anything else is a rule.
fn severity(text: &str) -> Severity {
    if ADVISORY.is_match(text) && !FIRM.is_match(text) { Severity::Warning } else { Severity::Error }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::question::{Kind, Question};
    use crate::rule::Scope;

    const SERVICES: &str = "\
---
paths: [\"src/services/*.ts\"]
excludes: [\"src/services/legacy.ts\"]
---
# Service conventions

Every file here is one service.

- **Domain failures are values, never exceptions.** A service returns
  `{ ok: false, error }` for anything a caller could cause.
- Services should prefer small inputs.
  - Nested detail stays with its bullet.

```ts
- not a rule, it's in a code fence
```

1. **No I/O except through the injected Store**: no timers, no fetch.
";

    fn spec(path: &str, content: &str) -> Vec<Rule> {
        parse(path, content, 0.7, false).unwrap()
    }

    fn ids(rules: &[Rule]) -> Vec<&str> {
        rules.iter().map(|r| r.id.as_str()).collect()
    }

    #[test]
    fn leads_and_slugs() {
        assert_eq!(lead("**No silent rescues.** A rescue logs."), "No silent rescues.");
        assert_eq!(slug("**Components don't fetch.** x"), "components-don-t-fetch");
        assert_eq!(lead("Use a timeout: always"), "Use a timeout.");
        assert_eq!(severity("You should prefer this"), Severity::Warning);
        assert_eq!(severity("You should never"), Severity::Error);
    }

    #[test]
    fn bullets_with_examples() {
        let body = "- **No smells.**\n\n  Bad:\n\n  ```ruby\n  SMELL\n  ```\n\n  Good:\n\n  ```ruby\n  fine\n  ```\n";
        let found = bullets(body, 0);
        assert_eq!(found.len(), 1);
        let lines: Vec<usize> = found[0].examples.iter().map(|e| e.line).collect();
        assert_eq!(lines, [6, 12]);
        assert_eq!(found[0].examples[0].code, "SMELL\n");
        assert_eq!(found[0].examples[0].expected, Expected::Fail);
    }

    #[test]
    fn each_top_level_bullet_is_a_rule() {
        let rules = spec("src/services/README.md", SERVICES);
        assert_eq!(
            ids(&rules),
            [
                "src/services/domain-failures-are-values-never-exceptions",
                "src/services/services-should-prefer-small-inputs",
                "src/services/no-i-o-except-through-the",
            ]
        );
        let values = &rules[0];
        assert_eq!(
            values.convention.as_deref(),
            Some(
                "Domain failures are values, never exceptions. A service returns `{ ok: false, error }` \
                 for anything a caller could cause."
            )
        );
        assert_eq!(values.message, "Domain failures are values, never exceptions.");
        assert_eq!(values.paths.raw, ["src/services/*.ts"]);
        assert_eq!(values.excludes.raw, ["src/services/legacy.ts"]);
        assert_eq!(values.examples_dir, ".judgelint/examples/src/services/domain-failures-are-values-never-exceptions");
        assert_eq!(
            rules[1].convention.as_deref(),
            Some("Services should prefer small inputs. Nested detail stays with its bullet.")
        );
        assert_eq!(rules[2].message, "No I/O except through the injected Store.");
    }

    #[test]
    fn severity_follows_the_wording_unless_the_spec_sets_it() {
        let severities = |content: &str| -> Vec<&str> {
            spec("src/services/README.md", content).iter().map(Rule::severity).collect()
        };
        assert_eq!(severities(SERVICES), ["error", "warning", "error"]);
        let set = SERVICES.replace("excludes:", "severity: warning\nexcludes:");
        assert_eq!(severities(&set), ["warning", "warning", "warning"]);
    }

    #[test]
    fn cohorts_and_scope() {
        let features = spec(
            "src/features/README.md",
            "---\npaths: [\"src/features/*\"]\ncohort: by_directory\ncontext: [\"src/types.ts\"]\n---\n- One capability per feature.\n",
        );
        assert_eq!(ids(&features), ["src/features/one-capability-per-feature"]);
        assert_eq!(features[0].scope, Scope::Directory);
        assert_eq!(features[0].context, ["src/types.ts"]);
        let tests =
            spec("tests/README.md", "---\npaths: [\"tests/*.ts\"]\ncohort: by_file\n---\n- One expect per it.\n");
        assert_eq!(tests[0].scope, Scope::File);
        let docs = spec("docs.judgelint.md", "---\npaths: [\"docs/**/*.md\"]\n---\n- Headings are sentence case.\n");
        assert_eq!(ids(&docs), ["docs/headings-are-sentence-case"]);
        assert_eq!(docs[0].scope, Scope::Window);
    }

    #[test]
    fn readmes_without_paths_are_not_specs() {
        assert!(spec("README.md", "# A project\n\n- a bullet that isn't a rule\n").is_empty());
        assert!(spec("lib/README.md", "---\ntitle: notes\n---\n- also not a rule\n").is_empty());
        assert!(spec("src/README.md", "- **Not a rule.** A README needs paths: to be a spec.\n").is_empty());
    }

    #[test]
    fn a_rules_file_without_a_question_is_a_spec_and_needs_bullets() {
        let path = ".judgelint/rules/ruby.md";
        let rules =
            parse(path, "---\npaths: [\"**/*.rb\"]\n---\n- **No silent rescues.** Log or re-raise.\n", 0.7, true);
        assert_eq!(ids(&rules.unwrap()), ["ruby/no-silent-rescues"]);
        let error = parse(path, "---\npaths: [\"**/*.rb\"]\n---\nJust prose.\n", 0.7, true).err().unwrap();
        assert!(error.to_string().contains("needs a question, or bullets"), "{error}");
    }

    #[test]
    fn repeated_bullets_get_distinct_ids() {
        let rules = spec("README.md", "---\npaths: [\"**/*.rb\"]\n---\n- Keep it short.\n- Keep it short, really.\n");
        assert_eq!(ids(&rules), ["root/keep-it-short", "root/keep-it-short-really"]);
        let rules = spec("README.md", "---\npaths: [\"**/*.rb\"]\n---\n- Keep it short.\n- Keep it short!\n");
        assert_eq!(ids(&rules), ["root/keep-it-short", "root/keep-it-short-2"]);
    }

    #[test]
    fn unknown_spec_keys_and_cohorts_are_errors() {
        assert!(parse("README.md", "---\npaths: [\"x\"]\nquestions: oops\n---\n- A rule.\n", 0.7, false).is_err());
        assert!(parse("README.md", "---\npaths: [\"x\"]\ncohort: by_repo\n---\n- A rule.\n", 0.7, false).is_err());
    }

    #[test]
    fn violation_and_compliant_lines_are_the_criteria() {
        let rules = spec(
            "src/README.md",
            "---\npaths: [\"src/*.ts\"]\n---\n\
             - **No I/O except through the injected Store.** No timers, no fetch.\n  \
             violation: calls fetch, console, or a timer\n    \
             directly, outside the Store\n  \
             compliant: reads and writes only through the Store it's given\n\
             - Keep it short.\n",
        );
        let (io, short) = (&rules[0], &rules[1]);
        assert_eq!(io.convention.as_deref(), Some("No I/O except through the injected Store. No timers, no fetch."));
        assert_eq!(io.yes_means.as_deref(), Some("calls fetch, console, or a timer directly, outside the Store"));
        assert_eq!(io.no_means.as_deref(), Some("reads and writes only through the Store it's given"));
        let options = Question::new(io, 1, 40, Kind::Verdict, None, None).options;
        assert_eq!([&options[0].1, &options[1].1], [&io.yes_means, &io.no_means]);
        assert_eq!(short.yes_means, None);
        assert!(io.prose.as_deref().unwrap().contains("violation: calls fetch"), "the model reads the criteria too");
    }

    #[test]
    fn conventions_md_needs_no_frontmatter() {
        let root = spec("CONVENTIONS.md", "# How we write code\n\n- **No silent rescues.** Log or re-raise.\n");
        let root = &root[0];
        assert_eq!(root.id, "root/no-silent-rescues");
        assert_eq!(root.paths.raw, ["**/*"]);
        assert!(root.applies_to("lib/a.rb"));
        assert!(!root.applies_to("docs/guide.md"), "Markdown is documentation, not code");
        assert!(!root.applies_to("Gemfile.lock"));
        assert!(root.prose.as_deref().unwrap().contains("# How we write code"));

        let api = spec(
            "src/api/CONVENTIONS.md",
            "---\nexcludes: [\"src/api/generated/**\"]\n---\n- Handlers should stay short.\n",
        );
        let api = &api[0];
        assert_eq!(api.id, "src/api/handlers-should-stay-short");
        assert_eq!(api.severity, Severity::Warning);
        assert!(api.applies_to("src/api/users.ts"));
        assert!(!api.applies_to("src/web/users.ts"), "a spec covers its own directory");
        assert!(!api.applies_to("src/api/generated/client.ts"));
    }

    #[test]
    fn bad_and_good_blocks_under_a_bullet_are_examples() {
        let content = "\
---
severity: warning
---
- **No silent rescues.** Log or re-raise.

  Bad:

  ```ruby
  rescue StandardError
    nil
  ```

  **Good:**

  ```ruby
  rescue Timeout => e
    raise
  ```

  ```
  rescue => e
    log(e)
  ```

  The last one logs, so it's fine.

```ruby
# Top-level code isn't an example.
```

- Keep it short.
";
        let rules = spec("CONVENTIONS.md", content);
        let (rescues, short) = (&rules[0], &rules[1]);
        assert_eq!(rescues.convention.as_deref(), Some("No silent rescues. Log or re-raise."));
        let examples: Vec<(Expected, usize, String)> =
            rescues.inline_examples.iter().map(|e| (e.expected, e.line, e.name())).collect();
        assert_eq!(
            examples,
            [
                (Expected::Fail, 9, "example.ruby".into()),
                (Expected::Pass, 16, "example.ruby".into()),
                (Expected::Pass, 21, "example".into()),
            ]
        );
        assert_eq!(rescues.inline_examples[0].code, "rescue StandardError\n  nil\n");
        assert!(short.inline_examples.is_empty());
        assert!(rescues.prose.as_deref().unwrap().contains("rescue StandardError"), "the model reads the examples");
    }
}
