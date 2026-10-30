//! Prints results as text, JSON, GitHub Actions annotations, or SARIF. Data
//! goes to stdout; anything else goes to stderr.

use std::io::{self, Write};

use clap::ValueEnum;
use serde::Serialize;
use serde::ser::Serializer;
use serde_json::json;

use crate::config::Config;
use crate::paint::{self, Paint};
use crate::rule::Rule;
use crate::usage::{self, Usage};
use crate::verdict::{Status, Verdict};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Copy, PartialEq, Eq, Debug, ValueEnum)]
pub enum Format {
    Text,
    Json,
    /// GitHub Actions annotations
    Github,
    Sarif,
}

pub struct Reporter<'a> {
    out: &'a mut dyn Write,
    format: Format,
    /// Colors the text format; the others are never colored.
    paint: Paint,
    rules: &'a [Rule],
}

#[derive(Serialize, Default)]
struct Summary {
    violation: usize,
    uncertain: usize,
    pass: usize,
    skipped: usize,
    refused: usize,
    excused: usize,
}

impl Summary {
    fn of(verdicts: &[&Verdict]) -> Summary {
        let mut summary = Summary::default();
        for verdict in verdicts {
            *match verdict.status {
                Status::Violation => &mut summary.violation,
                Status::Uncertain => &mut summary.uncertain,
                Status::Pass => &mut summary.pass,
                Status::Skipped => &mut summary.skipped,
                Status::Refused => &mut summary.refused,
                Status::Excused => &mut summary.excused,
            } += 1;
        }
        summary
    }
}

#[derive(Serialize)]
struct Finding<'a> {
    path: &'a str,
    lines: Option<[u32; 2]>,
    line: Option<u32>,
    file: Option<&'a str>,
    rule: &'a str,
    severity: &'a str,
    status: &'a str,
    probability: Option<f64>,
    message: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    expected: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    correct: Option<bool>,
}

/// The verdicts as findings, serialized one at a time: a run's can be many.
struct Findings<'a>(&'a [&'a Verdict], &'a [Rule]);

impl Serialize for Findings<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(self.0.iter().map(|v| {
            let rule = &self.1[v.rule];
            Finding {
                path: &v.path,
                lines: v.lines.map(|(a, b)| [a, b]),
                line: v.line,
                file: v.file.as_deref(),
                rule: &rule.id,
                severity: rule.severity(),
                status: v.status.name(),
                probability: v.probability.map(|p| (p * 1000.0).round() / 1000.0),
                message: &rule.message,
                expected: v.expected.map(|e| e.name()),
                correct: v.expected.map(|_| v.correct()),
            }
        }))
    }
}

#[derive(Serialize)]
struct CheckReport<'a> {
    version: &'a str,
    models: Vec<String>,
    files: usize,
    summary: Summary,
    usage: usage::Summary,
    results: Findings<'a>,
}

#[derive(Serialize)]
struct TestReport<'a> {
    version: &'a str,
    correct: usize,
    total: usize,
    usage: usage::Summary,
    examples: Findings<'a>,
}

fn chars(text: &str) -> usize {
    text.chars().count()
}

/// Groups by a key, in the order keys first appear.
fn group_by<'v, K: PartialEq>(items: &[&'v Verdict], key: impl Fn(&Verdict) -> K) -> Vec<(K, Vec<&'v Verdict>)> {
    let mut groups: Vec<(K, Vec<&Verdict>)> = Vec::new();
    for &item in items {
        let k = key(item);
        // Consecutive items usually share a key.
        let found = groups
            .last()
            .filter(|(g, _)| *g == k)
            .map(|_| groups.len() - 1)
            .or_else(|| groups.iter().position(|(g, _)| *g == k));
        match found {
            Some(i) => groups[i].1.push(item),
            None => groups.push((k, vec![item])),
        }
    }
    groups
}

/// A writer for JSON that writes each `#` after another as `\u0023`. CI
/// systems read a command from `##` anywhere in a line, like `##[error]` or
/// `##vso[`, and a file name can hold one; the escape reads back the same,
/// and `#` only appears in JSON inside a string.
struct Commands<W> {
    out: W,
    hash: bool,
}

impl<W: Write> Commands<W> {
    fn new(out: W) -> Self {
        Commands { out, hash: false }
    }
}

impl<W: Write> Write for Commands<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut start = 0;
        for (i, &b) in buf.iter().enumerate() {
            if b == b'#' && self.hash {
                self.out.write_all(&buf[start..i])?;
                self.out.write_all(b"\\u0023")?;
                start = i + 1;
                self.hash = false;
            } else {
                self.hash = b == b'#';
            }
        }
        self.out.write_all(&buf[start..])?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.out.flush()
    }
}

impl<'a> Reporter<'a> {
    pub fn new(out: &'a mut dyn Write, format: Format, paint: Paint, rules: &'a [Rule]) -> Self {
        Reporter { out, format, paint, rules }
    }

    pub fn check(
        &mut self,
        verdicts: &[&Verdict],
        config: &Config,
        file_count: usize,
        usage: &Usage,
    ) -> io::Result<()> {
        match self.format {
            Format::Json => {
                let report = CheckReport {
                    version: VERSION,
                    models: config.models.iter().map(|m| m.label()).collect(),
                    files: file_count,
                    summary: Summary::of(verdicts),
                    usage: usage.summary(),
                    results: Findings(verdicts, self.rules),
                };
                serde_json::to_writer_pretty(Commands::new(&mut *self.out), &report)?;
                writeln!(self.out)
            }
            Format::Github => verdicts.iter().try_for_each(|v| self.annotate(v)),
            Format::Sarif => {
                let sarif = self.sarif(verdicts);
                serde_json::to_writer_pretty(Commands::new(&mut *self.out), &sarif)?;
                writeln!(self.out)
            }
            Format::Text => self.text(verdicts, file_count),
        }
    }

    pub fn fixtures(&mut self, examples: &[&Verdict], usage: &Usage) -> io::Result<()> {
        let correct = examples.iter().filter(|e| e.correct()).count();
        if self.format == Format::Json {
            let report = TestReport {
                version: VERSION,
                correct,
                total: examples.len(),
                usage: usage.summary(),
                examples: Findings(examples, self.rules),
            };
            serde_json::to_writer_pretty(Commands::new(&mut *self.out), &report)?;
            return writeln!(self.out);
        }
        for (rule, group) in group_by(examples, |v| v.rule) {
            let right = group.iter().filter(|e| e.correct()).count();
            let tone = if right == group.len() { paint::GREEN } else { paint::RED };
            let tally = self.paint.call(&format!("{right}/{}", group.len()), tone);
            writeln!(self.out, "{}  {tally}", self.paint.call(&paint::clean(&self.rules[rule].id), paint::BOLD))?;
            for example in group {
                let mark = if example.correct() {
                    self.cell("ok", 4, paint::GREEN)
                } else {
                    self.paint.call("MISS", paint::BOLD_RED)
                };
                let expected = self.cell(example.expected.map_or("", |e| e.name()), 4, paint::DIM);
                let path = self.paint.call(&paint::clean(&example.path), paint::CYAN);
                writeln!(self.out, "  {mark} {expected} {}  {path}", probability(example))?;
            }
        }
        if !examples.is_empty() {
            writeln!(self.out)?;
        }
        let tone = if correct == examples.len() { paint::BOLD_GREEN } else { paint::BOLD_RED };
        let total = self.paint.call(&format!("{correct}/{} examples judged correctly", examples.len()), tone);
        writeln!(self.out, "{total}")
    }

    fn text(&mut self, verdicts: &[&Verdict], file_count: usize) -> io::Result<()> {
        let shown: Vec<&Verdict> = verdicts.iter().copied().filter(|v| v.status != Status::Pass).collect();
        let width = shown.iter().map(|v| chars(&self.rules[v.rule].id)).max().unwrap_or(0);
        let places = shown.iter().map(|v| chars(&range(v))).fold(7, usize::max);
        for (path, group) in group_by(&shown, |v| v.path.clone()) {
            writeln!(self.out, "{}", self.paint.call(&paint::clean(&path), paint::BOLD))?;
            for verdict in group {
                let line = self.line(verdict, width, places);
                writeln!(self.out, "  {line}")?;
            }
        }
        if !shown.is_empty() {
            writeln!(self.out)?;
        }
        let summary = self.summary(verdicts, file_count);
        writeln!(self.out, "{summary}")
    }

    /// Columns are padded before they're colored, so they line up either way.
    fn line(&self, verdict: &Verdict, width: usize, places: usize) -> String {
        let rule = &self.rules[verdict.rule];
        let label = if verdict.status == Status::Violation { rule.severity() } else { verdict.status.name() };
        let mark = match verdict.status {
            Status::Violation if self.paint.on() => "\u{2717}",
            Status::Violation => "x",
            Status::Uncertain => "?",
            _ => "-",
        };
        let tone = self.tone(verdict);
        [
            self.cell(&format!("{mark} {label}"), 12, tone),
            self.cell(&paint::clean(&rule.id), width, paint::DIM),
            format!(" {}", self.cell(&range(verdict), places, paint::CYAN)),
            format!("{} ", self.paint.call(&probability(verdict), tone)),
            paint::clean(&rule.message).into_owned(),
        ]
        .join(" ")
    }

    /// +text+ in color, padded to +width+ outside it.
    fn cell(&self, text: &str, width: usize, code: &str) -> String {
        format!("{}{}", self.paint.call(text, code), " ".repeat(width.saturating_sub(chars(text))))
    }

    /// Errors are red, warnings and uncertain findings yellow, the rest dim.
    fn tone(&self, verdict: &Verdict) -> &'static str {
        match verdict.status {
            Status::Uncertain => paint::YELLOW,
            Status::Violation if self.rules[verdict.rule].is_error() => paint::BOLD_RED,
            Status::Violation => paint::YELLOW,
            _ => paint::DIM,
        }
    }

    fn summary(&self, verdicts: &[&Verdict], file_count: usize) -> String {
        let counts = Summary::of(verdicts);
        let violations = counts.violation;
        let tone = if violations == 0 { paint::BOLD_GREEN } else { paint::BOLD_RED };
        let mut parts = vec![
            format!("{file_count} {}", if file_count == 1 { "file" } else { "files" }),
            self.paint.call(&format!("{violations} violations"), tone),
        ];
        for (n, text, tone) in [
            (counts.uncertain, "uncertain", paint::YELLOW),
            (counts.skipped, "skipped", paint::DIM),
            (counts.refused, "refused by the model", paint::DIM),
            (counts.excused, "excused by judgehints", paint::DIM),
        ] {
            if n > 0 {
                parts.push(self.paint.call(&format!("{n} {text}"), tone));
            }
        }
        parts.join(", ")
    }

    /// GitHub Actions workflow commands, which show up on the pull request's lines.
    fn annotate(&mut self, verdict: &Verdict) -> io::Result<()> {
        let rule = &self.rules[verdict.rule];
        let level = match verdict.status {
            Status::Violation if rule.is_error() => "error",
            Status::Violation => "warning",
            Status::Uncertain => "notice",
            _ => return Ok(()),
        };
        let mut properties = vec![format!("file={}", escape(verdict.file.as_deref().unwrap_or(&verdict.path), true))];
        if let Some(line) = verdict.line {
            properties.push(format!("line={line}"));
        } else if let Some((first, last)) = verdict.lines {
            properties.push(format!("line={first},endLine={last}"));
        }
        properties.push(format!("title={}", escape(&format!("judgelint {}", rule.id), true)));
        let message = escape(&format!("{} ({})", rule.message, probability(verdict)), false);
        writeln!(self.out, "::{level} {}::{message}", properties.join(","))
    }

    fn sarif(&self, verdicts: &[&Verdict]) -> serde_json::Value {
        let shown: Vec<&Verdict> =
            verdicts.iter().copied().filter(|v| matches!(v.status, Status::Violation | Status::Uncertain)).collect();
        let mut rules: Vec<usize> = Vec::new();
        for verdict in &shown {
            if !rules.contains(&verdict.rule) {
                rules.push(verdict.rule);
            }
        }
        let rule_entries: Vec<_> = rules
            .iter()
            .map(|&r| json!({"id": self.rules[r].id, "shortDescription": {"text": self.rules[r].message}}))
            .collect();
        let results: Vec<_> = shown
            .iter()
            .map(|verdict| {
                let rule = &self.rules[verdict.rule];
                let region = match (verdict.line, verdict.lines) {
                    (Some(line), _) => json!({"startLine": line}),
                    (None, Some((first, last))) => json!({"startLine": first, "endLine": last}),
                    _ => json!({}),
                };
                let level = match verdict.status {
                    Status::Uncertain => "note",
                    _ if rule.is_error() => "error",
                    _ => "warning",
                };
                let uri = verdict.file.as_deref().unwrap_or(&verdict.path);
                json!({
                    "ruleId": rule.id,
                    "level": level,
                    "message": {"text": format!("{} ({})", rule.message, probability(verdict))},
                    "locations": [{"physicalLocation": {"artifactLocation": {"uri": uri}, "region": region}}],
                })
            })
            .collect();
        json!({
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [{
                "tool": {"driver": {
                    "name": "judgelint",
                    "version": VERSION,
                    "informationUri": "https://github.com/jpcamara/judgelint",
                    "rules": rule_entries,
                }},
                "results": results,
            }],
        })
    }
}

/// The line that breaks the rule, or the range asked about; for a
/// directory, the file in it.
fn range(verdict: &Verdict) -> String {
    if let Some(file) = &verdict.file {
        return paint::clean(file.strip_prefix(&format!("{}/", verdict.path)).unwrap_or(file)).into_owned();
    }
    match (verdict.line, verdict.lines) {
        (Some(line), _) => line.to_string(),
        (None, Some((first, last))) => format!("{first}-{last}"),
        _ => String::new(),
    }
}

fn probability(verdict: &Verdict) -> String {
    verdict.probability.map_or_else(|| "  - ".into(), |p| format!("{p:.2}"))
}

fn escape(text: &str, property: bool) -> String {
    let escaped = text.replace('%', "%25").replace('\r', "%0D").replace('\n', "%0A");
    if property { escaped.replace(':', "%3A").replace(',', "%2C") } else { escaped }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_escapes_ci_commands_and_reads_back_the_same() {
        let paths = ["##[error]forged.rb", "##vso[task.uploadfile]/etc/passwd", "a###b", "issue #1"];
        let mut out = Vec::new();
        serde_json::to_writer_pretty(Commands::new(&mut out), &paths).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(!text.contains("##"), "{text}");
        assert_eq!(serde_json::from_str::<Vec<String>>(&text).unwrap(), paths);

        let mut out = Vec::new();
        let mut split = Commands::new(&mut out);
        split.write_all(b"\"a#").unwrap();
        split.write_all(b"#\"").unwrap();
        assert_eq!(out, b"\"a#\\u0023\"", "a pair split across writes");
    }
}
