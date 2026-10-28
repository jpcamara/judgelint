//! The two request shapes decision models are served with. Each renders a
//! Question as a yes/no question or a choice, and reads back the probability
//! of yes, or a choice's probability for each option. A missing answer is a
//! refusal.

use anyhow::{Result, anyhow};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::question::Question;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    /// TypeSafe's System One: questions keyed by name, yes/no is "noul", and
    /// a choice's options are its criteria.
    SystemOne = 0,
    /// OpenAI's Decisions API: questions are a list with names, yes/no is
    /// "predicate" with no criteria field, a choice lists its options as
    /// {value, description}, and answers come back as a list.
    Decisions = 1,
}

/// One question's answer: the probability of yes, or a choice's probability
/// for each of its options, in order.
#[derive(Clone, Debug)]
pub enum Answer {
    Yes(f64),
    Choice(Vec<f64>),
}

impl Answer {
    /// What the cache keeps.
    pub fn values(&self) -> &[f64] {
        match self {
            Answer::Yes(p) => std::slice::from_ref(p),
            Answer::Choice(ps) => ps,
        }
    }

    /// A cached answer, if it fits the question.
    pub fn from_cached(question: &Question, values: Vec<f64>) -> Option<Answer> {
        match (question.choice, values.as_slice()) {
            (false, [p]) => Some(Answer::Yes(*p)),
            (true, _) if values.len() == question.options.len() => Some(Answer::Choice(values)),
            _ => None,
        }
    }
}

impl Protocol {
    /// Where the state goes in a request.
    pub fn state_key(self) -> &'static str {
        match self {
            Protocol::SystemOne => "state",
            Protocol::Decisions => "input",
        }
    }

    pub fn render(self, question: &Question) -> Value {
        match self {
            Protocol::SystemOne if question.choice => {
                let criteria: Map<String, Value> =
                    question.options.iter().map(|(name, about)| (name.clone(), json!(about))).collect();
                json!({"type": "choice", "instructions": question.instructions, "criteria": criteria})
            }
            Protocol::SystemOne => {
                let mut rendered = json!({"type": "noul", "instructions": question.instructions});
                let mut criteria = Map::new();
                if let Some(yes) = &question.yes_means {
                    criteria.insert("true".into(), json!(yes));
                }
                if let Some(no) = &question.no_means {
                    criteria.insert("false".into(), json!(no));
                }
                if !criteria.is_empty() {
                    rendered["criteria"] = Value::Object(criteria);
                }
                rendered
            }
            Protocol::Decisions if question.choice => {
                let choices: Vec<Value> = question
                    .options
                    .iter()
                    .map(|(value, about)| match about {
                        Some(about) => json!({"value": value, "description": about}),
                        None => json!({"value": value}),
                    })
                    .collect();
                json!({"type": "choice", "name": question.key, "instructions": question.instructions, "choices": choices})
            }
            Protocol::Decisions => {
                // A yes/no question's criteria become lines of its
                // instructions, as RubyLLM and LiteLLM do.
                let mut lines = vec![question.instructions.clone()];
                lines.extend(question.yes_means.as_ref().map(|yes| format!("Yes: {yes}")));
                lines.extend(question.no_means.as_ref().map(|no| format!("No: {no}")));
                json!({"type": "predicate", "name": question.key, "instructions": lines.join("\n")})
            }
        }
    }

    /// The request body; provider_options replace or add to what it has.
    pub fn payload(
        self,
        model: Option<&str>,
        questions: &[&Question],
        state: Value,
        options: &Map<String, Value>,
    ) -> Value {
        let mut body = Map::new();
        match self {
            Protocol::SystemOne => {
                let rendered: Map<String, Value> = questions.iter().map(|q| (q.key.clone(), self.render(q))).collect();
                body.insert("state".into(), state);
                body.insert("questions".into(), Value::Object(rendered));
                if let Some(model) = model.filter(|m| !m.is_empty()) {
                    body.insert("model".into(), json!(model));
                }
            }
            Protocol::Decisions => {
                body.insert("model".into(), json!(model));
                body.insert("input".into(), state);
                body.insert("questions".into(), questions.iter().map(|q| self.render(q)).collect());
            }
        }
        for (key, value) in options {
            body.insert(key.clone(), value.clone());
        }
        Value::Object(body)
    }

    /// Each question's answer, in order, or None for a refusal.
    pub fn parse(self, data: &Value, questions: &[&Question]) -> Result<Vec<Option<Answer>>> {
        let no_answers = || {
            let text = data.to_string();
            anyhow!("Response has no answers: {}", text.chars().take(200).collect::<String>())
        };
        match self {
            Protocol::SystemOne => {
                let answers = data.get("answers").and_then(Value::as_object).ok_or_else(no_answers)?;
                questions
                    .iter()
                    .map(|q| {
                        let answer = answers.get(&q.key);
                        if q.choice {
                            choice(answer, answer.and_then(|a| a.get("probabilities")).cloned(), q)
                        } else {
                            yes(answer, "noul", q)
                        }
                    })
                    .collect()
            }
            Protocol::Decisions => {
                let answers = data.get("answers").and_then(Value::as_array).ok_or_else(no_answers)?;
                // Answers come back in question order; match by name when there
                // is one, and give unnamed answers to the remaining questions.
                let name = |a: &Value| a.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                let mut unnamed = answers.iter().filter(|a| name(a).is_empty());
                questions
                    .iter()
                    .map(|q| {
                        let answer = answers.iter().find(|a| name(a) == q.key).or_else(|| unnamed.next());
                        if q.choice {
                            choice(answer, answer.and_then(listed), q)
                        } else {
                            yes(answer, "probability", q)
                        }
                    })
                    .collect()
            }
        }
    }
}

fn is_refusal(answer: Option<&Value>) -> bool {
    answer.and_then(|a| a.get("type")).and_then(Value::as_str) == Some("refusal")
}

fn shown(answer: Option<&Value>) -> String {
    answer.map_or_else(|| "nothing".into(), Value::to_string)
}

fn yes(answer: Option<&Value>, field: &str, question: &Question) -> Result<Option<Answer>> {
    if is_refusal(answer) {
        return Ok(None);
    }
    match answer.and_then(|a| a.get(field)).and_then(Value::as_f64) {
        Some(p) => Ok(Some(Answer::Yes(p))),
        None => Err(anyhow!("No yes/no answer for {}: {}", question.key, shown(answer))),
    }
}

fn choice(answer: Option<&Value>, probabilities: Option<Value>, question: &Question) -> Result<Option<Answer>> {
    if is_refusal(answer) {
        return Ok(None);
    }
    let Some(Value::Object(probabilities)) = probabilities else {
        return Err(anyhow!("No choice answer for {}: {}", question.key, shown(answer)));
    };
    let values = question
        .options
        .iter()
        .map(|(option, _)| probabilities.get(option).and_then(Value::as_f64).unwrap_or(0.0))
        .collect();
    Ok(Some(Answer::Choice(values)))
}

/// [{value, probability}] as {value: probability}.
fn listed(answer: &Value) -> Option<Value> {
    let list = answer.get("probabilities")?.as_array()?;
    let pairs = list.iter().map(|entry| {
        let value = entry.get("value").and_then(Value::as_str).unwrap_or("").to_string();
        (value, entry.get("probability").cloned().unwrap_or(Value::Null))
    });
    Some(Value::Object(pairs.collect()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::question::Kind;
    use crate::testing::rule;

    fn question(id: &str, yaml: &str, first: u32, last: u32) -> Question {
        Question::new(&rule(id, yaml), first, last, Kind::Verdict, None, None)
    }

    fn yes(answer: &Option<Answer>) -> Option<f64> {
        match answer {
            Some(Answer::Yes(p)) => Some(*p),
            _ => None,
        }
    }

    #[test]
    fn system_one_body() {
        let smell = question("smell", "yes_means: It smells.\nno_means: It doesn't.", 1, 40);
        let plain = question("plain", "", 41, 80);
        let body = Protocol::SystemOne.payload(Some("jev-latest"), &[&smell, &plain], json!("SMELL"), &Map::new());
        let expected = json!({
            "model": "jev-latest",
            "state": "SMELL",
            "questions": {
                "smell.1-40": {
                    "type": "noul",
                    "instructions": smell.instructions,
                    "criteria": {"true": "It smells.", "false": "It doesn't."},
                },
                "plain.41-80": {"type": "noul", "instructions": plain.instructions},
            },
        });
        assert_eq!(body, expected);
    }

    #[test]
    fn decisions_body() {
        let smell = question("smell", "yes_means: It smells.\nno_means: It doesn't.", 1, 40);
        let plain = question("plain", "", 1, 40);
        let body = Protocol::Decisions.payload(Some("gpt-6-luna"), &[&smell, &plain], json!("fine"), &Map::new());
        let expected = json!({
            "model": "gpt-6-luna",
            "input": "fine",
            "questions": [
                {
                    "type": "predicate",
                    "name": "smell.1-40",
                    "instructions": format!("{}\nYes: It smells.\nNo: It doesn't.", smell.instructions),
                },
                {"type": "predicate", "name": "plain.1-40", "instructions": plain.instructions},
            ],
        });
        assert_eq!(body, expected);
    }

    #[test]
    fn decisions_answers_match_by_name_then_by_order() {
        let (a, b) = (question("a", "", 1, 40), question("b", "", 1, 40));
        let data = json!({"answers": [
            {"type": "predicate", "name": "b.1-40", "probability": 0.2},
            {"type": "predicate", "probability": 0.7},
        ]});
        let answers = Protocol::Decisions.parse(&data, &[&a, &b]).unwrap();
        assert_eq!(answers.iter().map(yes).collect::<Vec<_>>(), [Some(0.7), Some(0.2)]);
    }

    #[test]
    fn refusals_are_none_not_errors() {
        let a = question("a", "", 1, 40);
        let data = json!({"answers": [{"type": "refusal", "name": "a.1-40"}]});
        assert!(Protocol::Decisions.parse(&data, &[&a]).unwrap()[0].is_none());
        let data = json!({"answers": {"a.1-40": {"type": "refusal"}}});
        assert!(Protocol::SystemOne.parse(&data, &[&a]).unwrap()[0].is_none());
    }

    #[test]
    fn missing_answers_are_errors() {
        let smell = question("smell", "", 1, 40);
        let error = Protocol::SystemOne.parse(&json!({"answers": {}}), &[&smell]).err().unwrap();
        assert!(error.to_string().contains("No yes/no answer for smell.1-40"), "{error}");
    }
}
