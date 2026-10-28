//! One rule asked about one range of a file. The model sees the whole file;
//! the question points at the lines. When a change touched only some of a
//! window's lines, it points at those, so code the change didn't touch can't
//! fail it.
//!
//! A spec's bullet is a choice between breaking the rule, following it, and
//! the rule not applying. The same request asks which line (or, for a
//! directory, which file) breaks the rule most clearly, so a finding can name
//! it. A rule written as a question is asked yes or no, as written. Code with
//! a judgehint comment is also asked, yes or no, whether the hint excuses it.
//!
//! Files share their questions, so a question works out its wording, options
//! and size once, while the run is planned, and keeps them.

use sha2::{Digest, Sha256};

use crate::protocol::Protocol;
use crate::rule::{Rule, Scope};

const BREAKS: &str = "The code clearly breaks the rule.";
const FOLLOWS: &str = "The code follows the rule.";
const NOT_APPLICABLE: &str = "The rule doesn't apply to this code.";
const EXCUSED: &str = "A judgehint comment is about this rule, and gives a reason the code may break it.";
const NOT_EXCUSED: &str =
    "No judgehint comment is about this rule. Any judgehint is about a different rule, or gives no reason.";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Verdict,
    Where,
    Excuse,
}

pub struct Question {
    pub first: u32,
    pub last: u32,
    pub kind: Kind,
    /// The changed lines in the range, or None to ask about all of it.
    pub lines: Option<Vec<u32>>,
    pub key: String,
    pub instructions: String,
    pub yes_means: Option<String>,
    pub no_means: Option<String>,
    /// A choice's options and their descriptions; empty for yes or no.
    pub options: Vec<(String, Option<String>)>,
    pub choice: bool,
    /// What the cache files its answers under.
    pub digest: String,
    /// What the question adds to a request, in each protocol.
    tokens: [usize; 2],
}

pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

impl Question {
    /// +places+ are a where question's options for a directory, its files as
    /// the model sees them; a window's are its line ids (L12).
    pub fn new(
        rule: &Rule,
        first: u32,
        last: u32,
        kind: Kind,
        places: Option<Vec<String>>,
        lines: Option<Vec<u32>>,
    ) -> Self {
        let choice = kind == Kind::Where || (kind == Kind::Verdict && rule.convention.is_some());
        let suffix = match kind {
            Kind::Excuse => ".excused",
            Kind::Where => ".where",
            Kind::Verdict => "",
        };
        let key = format!("{}.{first}-{last}{suffix}", rule.question_key);
        let options: Vec<(String, Option<String>)> = if kind == Kind::Where {
            let places = places.unwrap_or_else(|| (first..=last).map(|line| format!("L{line}")).collect());
            places.into_iter().map(|place| (place, None)).collect()
        } else if choice {
            vec![
                ("breaks".into(), Some(rule.yes_means.clone().unwrap_or_else(|| BREAKS.into()))),
                ("follows".into(), Some(rule.no_means.clone().unwrap_or_else(|| FOLLOWS.into()))),
                ("not_applicable".into(), Some(NOT_APPLICABLE.into())),
            ]
        } else {
            Vec::new()
        };
        let (yes_means, no_means) = match kind {
            Kind::Excuse => (Some(EXCUSED.to_string()), Some(NOT_EXCUSED.to_string())),
            _ if choice => (None, None),
            _ => (rule.yes_means.clone(), rule.no_means.clone()),
        };
        let instructions = instructions(rule, first, last, kind, lines.as_deref());
        let digest_input =
            (&instructions, yes_means.as_deref().unwrap_or(""), no_means.as_deref().unwrap_or(""), &options);
        let digest = sha256_hex(&serde_json::to_vec(&digest_input).unwrap_or_default());
        let mut question = Question {
            first,
            last,
            kind,
            lines,
            key,
            instructions,
            yes_means,
            no_means,
            options,
            choice,
            digest,
            tokens: [0; 2],
        };
        for protocol in [Protocol::SystemOne, Protocol::Decisions] {
            let rendered = protocol.render(&question).to_string().len();
            question.tokens[protocol as usize] = (rendered + question.key.len() + 6) / 3;
        }
        question
    }

    /// What one more question adds to a request, without serializing the
    /// file again.
    pub fn tokens(&self, protocol: Protocol) -> usize {
        self.tokens[protocol as usize]
    }
}

/// "Answer yes only when..." keeps the model from flagging code the rule
/// doesn't cover.
fn instructions(rule: &Rule, first: u32, last: u32, kind: Kind, lines: Option<&[u32]>) -> String {
    let convention = rule.convention.as_deref().unwrap_or("");
    match kind {
        Kind::Excuse => {
            let place = match rule.scope {
                Scope::Window => format!("in lines {first}-{last} of the file"),
                Scope::File => "in the file".into(),
                Scope::Directory => "in the files".into(),
            };
            let named = rule.convention.as_deref().unwrap_or(&rule.message);
            format!(
                "Does a judgehint comment {place} explain why the code intentionally departs from the following team rule, with a reason specific to this rule? Rule: {named}"
            )
        }
        Kind::Where => {
            let which =
                if rule.is_directory() { "Which file" } else { "Which line, given by its number as L<number>," };
            format!("{which} most clearly breaks the following team rule? Rule: {convention}")
        }
        Kind::Verdict if rule.convention.is_some() => {
            let verb = if rule.scope == Scope::File || lines.is_some_and(|l| l.len() == 1) { "does" } else { "do" };
            let subject = match rule.scope {
                Scope::Window => format!("{} of the file", span(first, last, lines)),
                Scope::File => "the file".into(),
                Scope::Directory => "the files".into(),
            };
            format!("How {verb} {subject} relate to the following team rule? Rule: {convention}")
        }
        Kind::Verdict => {
            let question = rule.question.as_deref().unwrap_or("");
            let text = if rule.is_window() {
                format!("Look at {} of the file; the rest is context. {question}", span(first, last, lines))
            } else {
                question.to_string()
            };
            if !rule.fail_when_yes {
                return text;
            }
            let scope = match rule.scope {
                Scope::Window => "those lines do it",
                Scope::File => "the code does it",
                Scope::Directory => "the files do it",
            };
            format!("{text} Answer yes only when {scope}, not when the question doesn't apply.")
        }
    }
}

/// The lines asked about: "lines 41-80", or the changed ones, as "line 7" or
/// "lines 3, 7-9".
fn span(first: u32, last: u32, lines: Option<&[u32]>) -> String {
    let Some(lines) = lines else {
        return format!("lines {first}-{last}");
    };
    if let [line] = lines {
        return format!("line {line}");
    }
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for &line in lines {
        match runs.last_mut() {
            Some(run) if run.1 + 1 == line => run.1 = line,
            _ => runs.push((line, line)),
        }
    }
    let parts: Vec<String> =
        runs.iter().map(|&(a, b)| if a == b { a.to_string() } else { format!("{a}-{b}") }).collect();
    format!("lines {}", parts.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{bullet, rule};

    fn verdict(rule: &Rule, first: u32, last: u32, lines: Option<Vec<u32>>) -> Question {
        Question::new(rule, first, last, Kind::Verdict, None, lines)
    }

    #[test]
    fn wording() {
        let window = verdict(&rule("smell", ""), 41, 80, None);
        assert_eq!(window.key, "smell.41-80");
        assert_eq!(
            window.instructions,
            "Look at lines 41-80 of the file; the rest is context. Does this code smell? \
             Answer yes only when those lines do it, not when the question doesn't apply."
        );

        let file = verdict(&rule("smell", "scope: file"), 1, 100, None);
        assert_eq!(
            file.instructions,
            "Does this code smell? Answer yes only when the code does it, not when the question doesn't apply."
        );

        let changed = verdict(&rule("smell", ""), 41, 80, Some(vec![43, 50, 51, 52]));
        assert_eq!(changed.key, "smell.41-80");
        assert_eq!(
            changed.instructions,
            "Look at lines 43, 50-52 of the file; the rest is context. Does this code smell? \
             Answer yes only when those lines do it, not when the question doesn't apply."
        );

        assert_eq!(
            verdict(&bullet("No fetch."), 1, 40, Some(vec![7])).instructions,
            "How does line 7 of the file relate to the following team rule? Rule: No fetch."
        );

        let validates = rule("smell", "question: Does it validate input first?\nfail_when: no");
        assert_eq!(verdict(&validates, 1, 100, None).instructions, "Does it validate input first?");
    }

    #[test]
    fn a_convention_is_a_choice_and_asks_where() {
        let rule = bullet("No fetch outside the Store.");
        let verdict = verdict(&rule, 41, 80, None);
        let places = Some(vec!["L41".to_string(), "L42".to_string()]);
        let place = Question::new(&rule, 41, 80, Kind::Where, places, None);

        assert_eq!([verdict.key.as_str(), place.key.as_str()], ["README.41-80", "README.41-80.where"]);
        assert!(verdict.choice && place.choice);
        assert_eq!(
            verdict.instructions,
            "How do lines 41-80 of the file relate to the following team rule? Rule: No fetch outside the Store."
        );
        let options: Vec<(&str, Option<&str>)> =
            verdict.options.iter().map(|(name, about)| (name.as_str(), about.as_deref())).collect();
        assert_eq!(
            options,
            [
                ("breaks", Some("The code clearly breaks the rule.")),
                ("follows", Some("The code follows the rule.")),
                ("not_applicable", Some("The rule doesn't apply to this code.")),
            ]
        );
        assert_eq!(
            place.instructions,
            "Which line, given by its number as L<number>, most clearly breaks the following team rule? \
             Rule: No fetch outside the Store."
        );
        assert_eq!(place.options, [("L41".to_string(), None), ("L42".to_string(), None)]);
    }
}
