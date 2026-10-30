//! One rule's outcome for one file.
//!
//! +status+ is Violation (at or above the rule's threshold), Uncertain
//! (between warn_at and the threshold), Pass, Skipped (the file can't be
//! sent: too large, or, in a change, binary or outside the project), Refused
//! (the model declined a question the verdict needed), or Excused (a
//! violation or uncertain, but a judgehint excuses it). +lines+ is the
//! [first, last] range the verdict came from. +line+ is the line in it that
//! breaks the rule, and +file+ the file in a directory, when the model could
//! say. An example's verdict also knows the answer it should have had.

use std::sync::Arc;

use crate::rule::{Expected, Rule};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status {
    Violation,
    Uncertain,
    Pass,
    Skipped,
    Refused,
    Excused,
}

impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Status::Violation => "violation",
            Status::Uncertain => "uncertain",
            Status::Pass => "pass",
            Status::Skipped => "skipped",
            Status::Refused => "refused",
            Status::Excused => "excused",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Verdict {
    pub rule: usize,
    pub path: Arc<str>,
    pub status: Status,
    pub probability: Option<f64>,
    pub lines: Option<(u32, u32)>,
    pub line: Option<u32>,
    pub file: Option<String>,
    pub expected: Option<Expected>,
}

impl Verdict {
    pub fn new(rule: usize, path: Arc<str>, status: Status) -> Verdict {
        Verdict { rule, path, status, probability: None, lines: None, line: None, file: None, expected: None }
    }

    /// +probability+ is the probability the code breaks the rule.
    pub fn classify(rule: &Rule, index: usize, path: Arc<str>, probability: f64, warn_at: f64) -> Verdict {
        let status = if probability >= rule.threshold {
            Status::Violation
        } else if probability >= warn_at {
            Status::Uncertain
        } else {
            Status::Pass
        };
        Verdict { probability: Some(probability), ..Verdict::new(index, path, status) }
    }

    pub fn failing(&self, rules: &[Rule]) -> bool {
        self.status == Status::Violation && rules[self.rule].is_error()
    }

    /// A refused or skipped example is a miss either way: the rule didn't
    /// work on it. An excused one isn't a violation.
    pub fn correct(&self) -> bool {
        if matches!(self.status, Status::Refused | Status::Skipped) {
            return false;
        }
        (self.status == Status::Violation) == (self.expected == Some(Expected::Fail))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::rule;

    #[test]
    fn thresholds_and_the_uncertain_band() {
        let rule = rule("smell", "");
        for (probability, status) in [(0.75, Status::Violation), (0.5, Status::Uncertain), (0.39, Status::Pass)] {
            assert_eq!(Verdict::classify(&rule, 0, "a.rb".into(), probability, 0.4).status, status, "{probability}");
        }
    }

    #[test]
    fn warnings_never_fail_the_run() {
        let rules = [rule("smell", "severity: warning"), rule("other", "")];
        let warning = Verdict::classify(&rules[0], 0, "a.rb".into(), 0.9, 0.4);
        assert_eq!(warning.status, Status::Violation);
        assert!(!warning.failing(&rules));
        assert!(Verdict::classify(&rules[1], 1, "a.rb".into(), 0.9, 0.4).failing(&rules));
    }

    #[test]
    fn an_excused_example_isnt_a_violation() {
        let example = |status, expected| Verdict { expected: Some(expected), ..Verdict::new(0, "a.rb".into(), status) };
        assert!(example(Status::Excused, Expected::Pass).correct());
        assert!(!example(Status::Excused, Expected::Fail).correct());
        assert!(!example(Status::Refused, Expected::Pass).correct());
    }
}
