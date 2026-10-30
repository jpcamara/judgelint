//! Judges files against the rules that govern them, and rules against their
//! examples, in two steps: plan every request first, so a run can be priced
//! and refused before anything is sent, then send them.
//!
//! Each file's requests carry the whole numbered file as state and one
//! question per rule and window, so a file's verdicts never depend on which
//! other files ran alongside it. Every model is asked every question, all of
//! a file's requests go out at once, and a question's answer is the models'
//! average. A rule's verdict is its worst window.
//!
//! Planning reads and hashes files in parallel; the jobs keep the order the
//! files were given in, so output doesn't depend on timing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use rayon::prelude::*;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::cache::{self, Cache};
use crate::changes::{Changed, Changes};
use crate::client::Client;
use crate::config::{Config, THREADS, WINDOW_LINES};
use crate::glob;
use crate::protocol::{Answer, Protocol};
use crate::question::{Kind, Question, hex};
use crate::rule::{Expected, Rule};
use crate::source::Source;
use crate::verdict::{Status, Verdict};

/// A finding names a line or file when it gets at least this share of the
/// "where" answer.
const PLACE_AT: f64 = 0.5;
/// A choice takes at most this many options.
const MAX_OPTIONS: usize = 255;
/// A file's requests in flight at once.
const REQUESTS_AT_ONCE: usize = 16;

/// One rule's questions about a file, shared by the files that match.
type Questions = Arc<Vec<Arc<Question>>>;

/// A file's questions by rule, and all of them in order.
pub struct QuestionSet {
    by_rule: Vec<(usize, Questions)>,
    flat: Vec<Arc<Question>>,
}

impl QuestionSet {
    fn new(by_rule: Vec<(usize, Questions)>) -> Self {
        let flat = by_rule.iter().flat_map(|(_, qs)| qs.iter().cloned()).collect();
        QuestionSet { by_rule, flat }
    }
}

/// Questions sent together to one model, and their estimated input tokens.
struct Request {
    model: usize,
    questions: Vec<u32>,
    tokens: usize,
}

/// One file's work: the questions to ask, each model's answers (from the
/// cache or the model), and the requests still to send. A job the cache
/// answers in full is settled as soon as it's packed, and any other once
/// it's sent.
pub struct Job {
    source: Option<Box<Source>>,
    path: Arc<str>,
    prose: Option<Arc<str>>,
    state_digest: [u8; 32],
    /// The state's JSON length in each protocol.
    state_len: [usize; 2],
    questions: Arc<QuestionSet>,
    /// By model, by question: the answer, if there's one yet.
    answers: Vec<Vec<Option<Answer>>>,
    requests: Vec<Request>,
    expected: Option<Expected>,
    skipped: bool,
    verdicts: Option<Vec<Verdict>>,
}

impl Job {
    pub fn verdicts(&self) -> &[Verdict] {
        self.verdicts.as_deref().unwrap_or(&[])
    }

    /// The state, read again, which must be the one planned: a file that
    /// changed since would be cached under the wrong contents.
    fn state(&self) -> Result<(Value, Vec<u8>)> {
        let changed = || anyhow!("{} changed while judgelint ran; run it again", self.path);
        let source = self.source.as_ref().ok_or_else(changed)?;
        let read = source.read_all().map_err(|_| changed())?;
        let (state, json, digest) = state(source, &read, self.prose.as_deref()).map_err(|_| changed())?;
        if digest != self.state_digest {
            return Err(changed());
        }
        Ok((state, json))
    }

    /// Keeps the verdicts and lets go of what made them.
    fn settle(&mut self, verdicts: Vec<Verdict>) {
        self.verdicts = Some(verdicts);
        self.answers = Vec::new();
        self.source = None;
        self.requests = Vec::new();
    }
}

/// The state, its JSON and the JSON's SHA-256.
fn state(source: &Source, read: &[String], prose: Option<&str>) -> Result<(Value, Vec<u8>, [u8; 32])> {
    let state = source.state(read, prose)?;
    let json = serde_json::to_vec(&state)?;
    let digest = Sha256::digest(&json).into();
    Ok((state, json, digest))
}

/// One range's averaged answers: the probability it breaks the rule, and
/// where, when the models are sure enough of one line or file.
struct Window {
    first: u32,
    last: u32,
    probability: f64,
    place: Option<String>,
}

pub struct Runner<'a> {
    config: &'a Config,
    rules: &'a [Rule],
    /// A model is asked with the Decisions protocol, which sends a
    /// structured state as text.
    decisions: bool,
    asked: Mutex<HashMap<(usize, String), Questions>>,
    asked_together: Mutex<HashMap<String, Arc<QuestionSet>>>,
    /// Rules that read the same context files and prose share an id.
    context_group: Vec<usize>,
    context_files: Mutex<HashMap<usize, Arc<Vec<String>>>>,
    pub untested: Vec<usize>,
}

impl<'a> Runner<'a> {
    pub fn new(config: &'a Config, rules: &'a [Rule]) -> Self {
        let mut context_group = Vec::with_capacity(rules.len());
        for (i, rule) in rules.iter().enumerate() {
            let same = rules[..i].iter().position(|other| other.context == rule.context && other.prose == rule.prose);
            context_group.push(same.map_or(i, |j| context_group[j]));
        }
        Runner {
            config,
            rules,
            decisions: config.models.iter().any(|m| m.protocol == Protocol::Decisions),
            asked: Mutex::default(),
            asked_together: Mutex::default(),
            context_group,
            context_files: Mutex::default(),
            untested: Vec::new(),
        }
    }

    /// The context files a group of rules reads, globbed once a run.
    fn context_for(&self, rule: usize) -> Result<Arc<Vec<String>>> {
        let group = self.context_group[rule];
        if let Some(found) = self.context_files.lock().unwrap_or_else(|e| e.into_inner()).get(&group) {
            return Ok(found.clone());
        }
        let files = glob::expand(&self.rules[group].context)?;
        // Context is sent like the code, so it follows the same rules.
        for file in &files {
            glob::read_text(file).with_context(|| format!("Context of {}", self.rules[group].id))?;
        }
        let files = Arc::new(files);
        self.context_files.lock().unwrap_or_else(|e| e.into_inner()).insert(group, files.clone());
        Ok(files)
    }

    /// Rules that read different context files or spec prose can't share a
    /// request, so a file gets one job per set of context files.
    fn by_context(&self, rules: impl Iterator<Item = usize>) -> Vec<Vec<usize>> {
        let mut groups: Vec<(usize, Vec<usize>)> = Vec::new();
        for rule in rules {
            let id = self.context_group[rule];
            match groups.iter_mut().find(|(g, _)| *g == id) {
                Some((_, members)) => members.push(rule),
                None => groups.push((id, vec![rule])),
            }
        }
        groups.into_iter().map(|(_, members)| members).collect()
    }

    /// A file's jobs, from its contents: one per set of context files the
    /// rules that govern it read. +lines+ limits it to the windows a change
    /// touched; a window rule is asked about the changed lines alone, with
    /// the rest of the file as context.
    pub fn prepare_file(&self, path: &str, contents: String, lines: Option<&Changed>) -> Result<Vec<Job>> {
        let applicable =
            (0..self.rules.len()).filter(|&i| !self.rules[i].is_directory() && self.rules[i].applies_to(path));
        let read = vec![contents];
        let mut jobs = Vec::with_capacity(1);
        for group in self.by_context(applicable) {
            let source = Source::file(path, None, self.context_for(group[0])?, None).scan(&read);
            jobs.push(self.plan(source, &read, &group, lines, None)?);
        }
        Ok(jobs)
    }

    /// The jobs of a file too large to read, which are reported as skipped:
    /// planned as one line so every rule that governs it has a verdict.
    pub fn skip_file(&self, path: &str) -> Result<Vec<Job>> {
        let mut jobs = self.prepare_file(path, "\n".into(), Some(&Changed::All))?;
        for job in &mut jobs {
            job.skipped = true;
        }
        Ok(jobs)
    }

    /// The directories directory rules govern; with a change, those it touched.
    pub fn plan_directories(&self, directories: &[String], changes: Option<&Changes>) -> Result<Vec<Job>> {
        let kept = |dir: &&String| {
            let prefix = format!("{dir}/");
            changes.is_none_or(|changes| changes.keys().any(|path| path.starts_with(&prefix)))
        };
        let planned: Vec<Result<Vec<Job>>> = directories
            .iter()
            .filter(kept)
            .collect::<Vec<_>>()
            .par_iter()
            .map(|dir| {
                let applicable =
                    (0..self.rules.len()).filter(|&i| self.rules[i].is_directory() && self.rules[i].applies_to(dir));
                let mut jobs = Vec::new();
                for group in self.by_context(applicable) {
                    let source = Source::directory(dir, None, self.context_for(group[0])?)?;
                    let read = source.read_all()?;
                    let mut source = source.scan(&read);
                    let too_large = source.too_large;
                    // Planned as one line at least, so every rule has a verdict.
                    if too_large {
                        source.line_count = source.line_count.max(1);
                    }
                    let mut job = self.plan(source, &read, &group, Some(&Changed::All), None)?;
                    job.skipped |= too_large;
                    jobs.push(job);
                }
                Ok(jobs)
            })
            .collect();
        Ok(planned.into_iter().collect::<Result<Vec<_>>>()?.into_iter().flatten().collect())
    }

    /// Files under <examples>/pass and Good blocks under a spec's bullet must
    /// not be judged violations; files under <examples>/fail and Bad blocks
    /// must. The model sees each file's path relative to its pass/ or fail/
    /// directory, and a block as example.<language>, so neither gives the
    /// answer away. A rule with examples needs both kinds, checked before
    /// anything is sent; rules with none are listed in +untested+.
    pub fn plan_examples(&mut self) -> Result<Vec<Job>> {
        struct Work {
            rule: usize,
            path: String,
            shown: String,
            text: Option<Arc<str>>,
            expected: Expected,
        }
        let mut work: Vec<Work> = Vec::new();
        let mut missing: Vec<String> = Vec::new();
        self.untested.clear();
        for (index, rule) in self.rules.iter().enumerate() {
            let found = [Expected::Pass, Expected::Fail].map(|expected| (expected, example_paths(rule, expected)));
            let found = found.map(|(expected, paths)| paths.map(|paths| (expected, paths)));
            let [pass, fail] = found;
            let found = [pass?, fail?];
            let inline = if rule.is_directory() { &[][..] } else { &rule.inline_examples[..] };
            if found.iter().all(|(_, paths)| paths.is_empty()) && inline.is_empty() {
                self.untested.push(index);
                continue;
            }
            for (expected, paths) in found {
                let dir = format!("{}/{}", rule.examples_dir, expected.name());
                if paths.is_empty() && !inline.iter().any(|e| e.expected == expected) {
                    missing.push(if inline.is_empty() {
                        format!("{dir}/")
                    } else {
                        let block = if expected == Expected::Pass { "Good" } else { "Bad" };
                        format!("a {block} block under {}", rule.id)
                    });
                }
                for path in paths {
                    let shown = path.strip_prefix(&format!("{dir}/")).unwrap_or(&path).to_string();
                    work.push(Work { rule: index, path, shown, text: None, expected });
                }
            }
            for example in inline {
                work.push(Work {
                    rule: index,
                    path: format!("{}:{}", rule.source, example.line),
                    shown: example.name(),
                    text: Some(Arc::from(example.code.as_str())),
                    expected: example.expected,
                });
            }
        }
        if !missing.is_empty() {
            bail!("Examples need both kinds: add {}", missing.join(", "));
        }
        work.par_iter()
            .map(|w| {
                let context = self.context_for(w.rule)?;
                let source = if self.rules[w.rule].is_directory() {
                    Source::directory(&w.path, Some(&w.shown), context)?
                } else {
                    Source::file(&w.path, Some(&w.shown), context, w.text.clone())
                };
                let read = source.read_all()?;
                self.plan(source.scan(&read), &read, &[w.rule], Some(&Changed::All), Some(w.expected))
            })
            .collect()
    }

    fn plan(
        &self,
        source: Source,
        read: &[String],
        rules: &[usize],
        lines: Option<&Changed>,
        expected: Option<Expected>,
    ) -> Result<Job> {
        let mut by_rule: Vec<(usize, Questions)> = Vec::new();
        let mut shapes: Vec<String> = Vec::new();
        let mut shared = true;
        for &index in rules {
            let rule = &self.rules[index];
            let ranges: Vec<(u32, u32)> =
                rule.ranges(&source, WINDOW_LINES).into_iter().filter(|&(f, l)| touched(lines, f, l)).collect();
            if ranges.is_empty() {
                continue;
            }
            if rule.is_directory() {
                by_rule.push((index, Arc::new(self.ask_about(&source, index, &ranges, lines))));
                shared = false;
                continue;
            }
            let shape = self.shape(&source, index, &ranges, lines);
            shapes.push(format!("{index}:{shape}"));
            let questions = remembered(&self.asked, (index, shape), || self.ask_about(&source, index, &ranges, lines));
            by_rule.push((index, questions));
        }
        let questions = if shared {
            remembered(&self.asked_together, shapes.join("|"), || QuestionSet::new(by_rule))
        } else {
            Arc::new(QuestionSet::new(by_rule))
        };
        let prose = rules.first().and_then(|&r| self.rules[r].prose.clone());
        let (_, json, state_digest) = state(&source, read, prose.as_deref())?;
        // Decisions sends a structured state as its JSON text.
        let decisions = if self.decisions && prose.is_some() {
            2 + json.len() + json.iter().filter(|&&b| b == b'"' || b == b'\\').count()
        } else {
            json.len()
        };
        Ok(Job {
            path: source.path.clone(),
            source: Some(Box::new(source)),
            prose,
            state_digest,
            state_len: [json.len(), decisions],
            answers: Vec::new(),
            questions,
            requests: Vec::new(),
            expected,
            skipped: false,
            verdicts: None,
        })
    }

    /// What decides a rule's questions about a file: its ranges, changed
    /// lines and judgehints. Files that match share their questions.
    fn shape(&self, source: &Source, rule: usize, ranges: &[(u32, u32)], lines: Option<&Changed>) -> String {
        let parts: Vec<String> = ranges
            .iter()
            .map(|&(first, last)| {
                let changed = changed_lines(&self.rules[rule], lines, first, last).unwrap_or_default();
                format!("{first}-{last}:{changed:?}:{}", source.hinted(first, last))
            })
            .collect();
        parts.join(";")
    }

    fn ask_about(
        &self,
        source: &Source,
        index: usize,
        ranges: &[(u32, u32)],
        lines: Option<&Changed>,
    ) -> Vec<Arc<Question>> {
        let rule = &self.rules[index];
        let mut asked = Vec::new();
        for &(first, last) in ranges {
            let changed = changed_lines(rule, lines, first, last);
            asked.push(Arc::new(Question::new(rule, first, last, Kind::Verdict, None, changed)));
            // Where a bullet is broken is asked over the range's lines or the
            // directory's files, but not for a rule written as a question, or
            // past what a choice can hold.
            let options = if rule.is_directory() { source.file_list().len() } else { (last - first + 1) as usize };
            if rule.convention.is_some() && options <= MAX_OPTIONS {
                let places =
                    rule.is_directory().then(|| source.members().into_iter().map(|(_, shown)| shown).collect());
                asked.push(Arc::new(Question::new(rule, first, last, Kind::Where, places, None)));
            }
            if source.hinted(first, last) {
                asked.push(Arc::new(Question::new(rule, first, last, Kind::Excuse, None, None)));
            }
        }
        asked
    }

    /// Looks every job's questions up in the cache and packs the rest into
    /// requests. A job the cache answers in full is settled.
    pub fn pack_all(&self, jobs: &mut [Job], clients: &[Client], cache: &Cache) -> Result<()> {
        // Each model's answers are cached on their own, so adding a model asks
        // only the new one.
        let labels: Vec<String> = clients.iter().map(|c| c.endpoint.cache_label.clone()).collect();
        jobs.par_iter_mut().try_for_each(|job| {
            self.pack(job, clients, &labels, cache)?;
            if job.requests.is_empty() {
                let verdicts = self.verdicts(job);
                job.settle(verdicts);
            }
            Ok(())
        })
    }

    /// For each model, packs the questions the cache can't answer into as
    /// few requests as fit its limits. A file whose state and widest question
    /// are over a model's limit is skipped: it's reported, never sent.
    fn pack(&self, job: &mut Job, clients: &[Client], labels: &[String], cache: &Cache) -> Result<()> {
        if job.skipped {
            return Ok(());
        }
        let questions = job.questions.clone();
        let state = hex(&job.state_digest);
        for (model, client) in clients.iter().enumerate() {
            let mut answers: Vec<Option<Answer>> = Vec::new();
            let mut pending: Vec<u32> = Vec::new();
            for (i, question) in questions.flat.iter().enumerate() {
                let key = cache::key(&question.digest, &state, &labels[model]);
                match cache.get(&key)?.and_then(|values| Answer::from_cached(question, values)) {
                    None => pending.push(i as u32),
                    Some(answer) => {
                        // A model's answers are kept only once it has one.
                        answers.resize_with(i, || None);
                        answers.push(Some(answer));
                    }
                }
            }
            if !answers.is_empty() {
                job.answers.resize_with(clients.len(), Vec::new);
                job.answers[model] = answers;
            }
            if pending.is_empty() {
                continue;
            }
            let limits = &client.endpoint;
            let protocol = client.protocol();
            let base = client.tokens(job.state_len[protocol as usize]);
            let sizes: Vec<usize> = pending.iter().map(|&i| questions.flat[i as usize].tokens(protocol)).collect();
            if base + sizes.iter().copied().max().unwrap_or(0) >= limits.max_state_tokens {
                job.skipped = true;
                job.requests.clear();
                return Ok(());
            }
            let mut batch: Vec<u32> = Vec::new();
            let mut tokens = base;
            for (&i, &size) in pending.iter().zip(&sizes) {
                if !batch.is_empty() && (tokens + size > limits.max_request_tokens || batch.len() >= limits.batch_size)
                {
                    job.requests.push(Request { model, questions: std::mem::take(&mut batch), tokens });
                    tokens = base;
                }
                batch.push(i);
                tokens += size;
            }
            job.requests.push(Request { model, questions: batch, tokens });
        }
        Ok(())
    }

    /// Every model the jobs will ask needs its key.
    pub fn check_keys(&self, jobs: &[Job], clients: &[Client]) -> Result<()> {
        let mut asked = vec![false; clients.len()];
        for request in jobs.iter().flat_map(|j| &j.requests) {
            asked[request.model] = true;
        }
        clients.iter().zip(asked).filter(|(_, asked)| *asked).try_for_each(|(client, _)| client.check_key())
    }

    pub fn request_count(&self, jobs: &[Job]) -> usize {
        jobs.iter().map(|j| j.requests.len()).sum()
    }

    pub fn estimated_tokens(&self, jobs: &[Job]) -> usize {
        jobs.iter().flat_map(|j| &j.requests).map(|r| r.tokens).sum()
    }

    /// None when a model has no price.
    pub fn estimated_cost(&self, jobs: &[Job], clients: &[Client]) -> Option<f64> {
        jobs.iter()
            .flat_map(|j| &j.requests)
            .map(|r| Some(r.tokens as f64 * clients[r.model].endpoint.price_per_million? / 1_000_000.0))
            .sum()
    }

    /// Sends what the cache couldn't answer and settles every job. Answers
    /// are saved to the cache even when a request fails.
    pub fn execute(&self, jobs: &mut [Job], clients: &[Client], cache: &Cache) -> Result<()> {
        let result = self.send_all(jobs, clients, cache);
        let saved = cache.flush();
        result.and(saved)
    }

    fn send_all(&self, jobs: &mut [Job], clients: &[Client], cache: &Cache) -> Result<()> {
        let open: Vec<Mutex<&mut Job>> = jobs.iter_mut().filter(|j| j.verdicts.is_none()).map(Mutex::new).collect();
        let next = AtomicUsize::new(0);
        let first_error: Mutex<Option<anyhow::Error>> = Mutex::new(None);
        std::thread::scope(|scope| {
            for _ in 0..THREADS.min(open.len()) {
                scope.spawn(|| {
                    while let Some(slot) = open.get(next.fetch_add(1, Ordering::Relaxed)) {
                        let mut job = slot.lock().unwrap_or_else(|e| e.into_inner());
                        if let Err(e) = self.ask(&mut job, clients, cache) {
                            first_error.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert(e);
                            continue;
                        }
                        let verdicts = self.verdicts(&job);
                        job.settle(verdicts);
                    }
                });
            }
        });
        match first_error.into_inner().unwrap_or_else(|e| e.into_inner()) {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Sends every request at once: a file's packed requests and every model's.
    fn ask(&self, job: &mut Job, clients: &[Client], cache: &Cache) -> Result<()> {
        let (state, json) = job.state()?;
        let questions = job.questions.clone();
        let send = |request: &Request| {
            let client = &clients[request.model];
            let state = if client.protocol() == Protocol::Decisions && job.prose.is_some() {
                Value::String(String::from_utf8_lossy(&json).into_owned())
            } else {
                state.clone()
            };
            let asked: Vec<&Question> = request.questions.iter().map(|&i| &*questions.flat[i as usize]).collect();
            client.judge(state, &asked)
        };
        let mut results: Vec<Result<Vec<Option<Answer>>>> = Vec::with_capacity(job.requests.len());
        for group in job.requests.chunks(REQUESTS_AT_ONCE) {
            match group {
                [request] => results.push(send(request)),
                requests => std::thread::scope(|scope| {
                    let handles: Vec<_> = requests.iter().map(|request| scope.spawn(|| send(request))).collect();
                    let joined =
                        handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err(anyhow!("a request failed"))));
                    results.extend(joined);
                }),
            }
        }
        let state = hex(&job.state_digest);
        job.answers.resize_with(clients.len(), Vec::new);
        for (request, answers) in job.requests.iter().zip(results) {
            let model = request.model;
            let label = &clients[model].endpoint.cache_label;
            let kept = &mut job.answers[model];
            kept.resize_with(questions.flat.len(), || None);
            for (&i, answer) in request.questions.iter().zip(answers?) {
                if let Some(answer) = &answer {
                    cache.put(&cache::key(&questions.flat[i as usize].digest, &state, label), answer.values())?;
                }
                kept[i as usize] = answer;
            }
        }
        Ok(())
    }

    fn verdicts(&self, job: &Job) -> Vec<Verdict> {
        let mut start = 0;
        job.questions
            .by_rule
            .iter()
            .map(|(rule, questions)| {
                let range = start..start + questions.len();
                start = range.end;
                Verdict { expected: job.expected, ..self.verdict_for(*rule, job, range) }
            })
            .collect()
    }

    /// A window's probability of a violation is the average of its verdict
    /// over the models, and its place is the line or file the models' "where"
    /// answers agree on. When a change touched only some of its lines, the
    /// probability counts only the share of "where" answers on those lines. A
    /// rule's verdict is its worst window. A window whose judgehint excuses
    /// it, by the same average and threshold, is reported as excused instead,
    /// unless another window breaks the rule.
    fn verdict_for(&self, rule: usize, job: &Job, range: std::ops::Range<usize>) -> Verdict {
        let path = job.path.clone();
        if job.skipped {
            return Verdict::new(rule, path, Status::Skipped);
        }
        let flat = &job.questions.flat;
        let threshold = self.rules[rule].threshold;
        let mut open = Vec::new();
        let mut excused = Vec::new();
        // The rule's questions come a range at a time, the verdict first.
        let mut i = range.start;
        while i < range.end {
            let (first, last) = (flat[i].first, flat[i].last);
            let mut values: Vec<f64> = Vec::new();
            let mut excuses: Vec<f64> = Vec::new();
            let mut spread: Vec<f64> = Vec::new();
            let mut place_question: Option<&Question> = None;
            let start = i;
            while i < range.end && (flat[i].first, flat[i].last) == (first, last) {
                let question = &*flat[i];
                for answer in job.answers.iter().filter_map(|answers| answers.get(i)?.as_ref()) {
                    match (question.kind, answer) {
                        (Kind::Excuse, Answer::Yes(p)) => excuses.push(*p),
                        (Kind::Where, Answer::Choice(ps)) => {
                            spread.resize(ps.len(), 0.0);
                            spread.iter_mut().zip(ps).for_each(|(sum, p)| *sum += p);
                            place_question = Some(question);
                        }
                        (Kind::Verdict, Answer::Choice(ps)) => values.push(ps[0]),
                        (Kind::Verdict, Answer::Yes(p)) => values.push(self.rules[rule].violation_probability(*p)),
                        _ => {}
                    }
                }
                i += 1;
            }
            if values.is_empty() {
                continue;
            }
            let mut probability = values.iter().sum::<f64>() / values.len() as f64;
            let places = place_question.map_or(&[][..], |q| &q.options[..]);
            if let Some(changed) = &flat[start].lines {
                probability *= changed_share(&spread, places, changed);
            }
            let place = agreed(&spread).map(|best| places[best].0.clone());
            let window = Window { first, last, probability, place };
            if !excuses.is_empty() && excuses.iter().sum::<f64>() / excuses.len() as f64 >= threshold {
                excused.push(window);
            } else {
                open.push(window);
            }
        }
        let found = self.worst(rule, &path, &open, job);
        if let Some(found) = found.as_ref().filter(|f| f.status != Status::Pass) {
            return found.clone();
        }
        match self.worst(rule, &path, &excused, job) {
            Some(hidden) if hidden.status != Status::Pass => Verdict { status: Status::Excused, ..hidden },
            hidden => found.or(hidden).unwrap_or_else(|| Verdict::new(rule, path, Status::Refused)),
        }
    }

    /// The worst of +windows+, or None if there are none.
    fn worst(&self, rule: usize, path: &Arc<str>, windows: &[Window], job: &Job) -> Option<Verdict> {
        let window = windows.iter().reduce(|worst, w| if w.probability > worst.probability { w } else { worst })?;
        let r = &self.rules[rule];
        let mut verdict = Verdict::classify(r, rule, path.clone(), window.probability, self.config.warn_at());
        if r.is_directory() {
            if let (Some(place), Some(source)) = (&window.place, &job.source) {
                verdict.file = source.members().into_iter().find(|(_, shown)| shown == place).map(|(file, _)| file);
            }
        } else {
            verdict.line = window.place.as_ref().and_then(|p| p.strip_prefix('L')?.parse().ok());
            verdict.lines = Some((window.first, window.last));
        }
        Some(verdict)
    }
}

/// A question set made once and shared by the files that ask it.
fn remembered<K: std::hash::Hash + Eq, T>(
    memo: &Mutex<HashMap<K, Arc<T>>>,
    key: K,
    make: impl FnOnce() -> T,
) -> Arc<T> {
    if let Some(found) = memo.lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return found.clone();
    }
    let made = Arc::new(make());
    memo.lock().unwrap_or_else(|e| e.into_inner()).entry(key).or_insert(made).clone()
}

/// A directory rule's examples are the directories under pass/ and fail/.
fn example_paths(rule: &Rule, expected: Expected) -> Result<Vec<String>> {
    let dir = format!("{}/{}", rule.examples_dir, expected.name());
    if rule.is_directory() { glob::directories(&format!("{dir}/*")) } else { glob::expand(&[format!("{dir}/**/*")]) }
}

/// The lines a change touched in a window rule's range, or None for all of them.
fn changed_lines(rule: &Rule, lines: Option<&Changed>, first: u32, last: u32) -> Option<Vec<u32>> {
    let Some(Changed::Lines(lines)) = lines else { return None };
    if !rule.is_window() {
        return None;
    }
    let mut changed: Vec<u32> = lines.iter().copied().filter(|&l| l >= first && l <= last).collect();
    changed.sort_unstable();
    changed.dedup();
    (changed.len() != (last - first + 1) as usize).then_some(changed)
}

fn touched(lines: Option<&Changed>, first: u32, last: u32) -> bool {
    match lines {
        Some(Changed::All) => true,
        Some(Changed::Lines(lines)) => lines.iter().any(|&l| l >= first && l <= last),
        None => false,
    }
}

/// The share of the summed "where" probabilities on +lines+, or all of it
/// when nothing answered where.
fn changed_share(spread: &[f64], places: &[(String, Option<String>)], lines: &[u32]) -> f64 {
    let total: f64 = spread.iter().sum();
    let on_lines: f64 = spread
        .iter()
        .zip(places)
        .filter(|(_, (place, _))| {
            place.strip_prefix('L').and_then(|n| n.parse().ok()).is_some_and(|n| lines.contains(&n))
        })
        .map(|(p, _)| p)
        .sum();
    if total > 0.0 { on_lines / total } else { 1.0 }
}

/// The place with at least PLACE_AT of the summed "where" probabilities.
fn agreed(spread: &[f64]) -> Option<usize> {
    let total: f64 = spread.iter().sum();
    let (best, value) = spread.iter().enumerate().reduce(|best, x| if x.1 > best.1 { x } else { best })?;
    (total > 0.0 && value / total >= PLACE_AT).then_some(best)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::config::Endpoint;
    use crate::glob::Patterns;
    use crate::testing::{TempDir, rule};

    /// One model, at an address where nothing answers: these tests plan
    /// requests without sending them.
    fn config(limits: Value) -> Config {
        let mut entry = json!({"api_base": "http://127.0.0.1:1", "model": "m", "auth": "none"});
        entry.as_object_mut().unwrap().extend(limits.as_object().unwrap().clone());
        Config {
            models: vec![Endpoint::new(entry).unwrap()],
            threshold: 0.7,
            ignore: Patterns::new(Vec::new()).unwrap(),
            max_cost_usd: 1.0,
        }
    }

    fn clients(config: &Config) -> Vec<Client> {
        config.models.iter().map(|e| Client::new(e.clone(), Arc::default()).unwrap()).collect()
    }

    fn plan(runner: &Runner, clients: &[Client], path: &str, contents: &str) -> Vec<Job> {
        let mut jobs = runner.prepare_file(path, contents.into(), Some(&Changed::All)).unwrap();
        runner.pack_all(&mut jobs, clients, &Cache::open(None).unwrap()).unwrap();
        jobs
    }

    #[test]
    fn files_with_the_same_shape_share_their_questions() {
        let (config, rules) = (config(json!({})), [rule("smell", "")]);
        let runner = Runner::new(&config, &rules);
        let a = runner.prepare_file("app/a.rb", "x\n".into(), Some(&Changed::All)).unwrap();
        let b = runner.prepare_file("app/b.rb", "y\n".into(), Some(&Changed::All)).unwrap();
        assert!(Arc::ptr_eq(&a[0].questions, &b[0].questions));
    }

    #[test]
    fn a_file_over_the_token_budget_is_skipped_before_anything_is_sent() {
        let (config, rules) = (config(json!({"max_state_tokens": 100})), [rule("smell", "")]);
        let runner = Runner::new(&config, &rules);
        let jobs = plan(&runner, &clients(&config), "app/a.rb", &"x".repeat(400));
        assert_eq!(runner.request_count(&jobs), 0);
        assert_eq!(jobs[0].verdicts()[0].status, Status::Skipped);
    }

    #[test]
    fn packs_questions_by_count_and_tokens() {
        let rules = [rule("a", ""), rule("b", "")];
        let file = "x\n".repeat(200);
        let config = config(json!({"batch_size": 4}));
        let runner = Runner::new(&config, &rules);
        let jobs = plan(&runner, &clients(&config), "app/a.rb", &file);
        let sizes: Vec<usize> = jobs[0].requests.iter().map(|r| r.questions.len()).collect();
        assert_eq!(sizes, [4, 4, 2]);
        assert_eq!(runner.request_count(&jobs), 3);
        assert_eq!(runner.estimated_tokens(&jobs), jobs[0].requests.iter().map(|r| r.tokens).sum::<usize>());

        let config = self::config(json!({"max_request_tokens": 120}));
        let runner = Runner::new(&config, &rules);
        assert!(runner.request_count(&plan(&runner, &clients(&config), "app/a.rb", &file)) > 3);
    }

    #[test]
    fn a_file_that_changes_or_goes_after_planning_is_not_sent() {
        let dir = TempDir::new();
        let (config, rules) = (config(json!({})), [rule("smell", "paths: [\"**/*.rb\"]")]);
        let runner = Runner::new(&config, &rules);
        let clients = clients(&config);
        let cache_path = dir.path("cache.bin");
        let cache = Cache::open(Some(&cache_path)).unwrap();
        for change in ["y\n", ""] {
            let path = dir.write("app/a.rb", "x\n");
            let mut jobs = plan(&runner, &clients, &path, &std::fs::read_to_string(&path).unwrap());
            if change.is_empty() {
                std::fs::remove_file(&path).unwrap();
            } else {
                std::fs::write(&path, change).unwrap();
            }
            let error = runner.execute(&mut jobs, &clients, &cache).unwrap_err();
            assert_eq!(error.to_string(), format!("{path} changed while judgelint ran; run it again"));
            assert!(!std::path::Path::new(&cache_path).exists());
        }
    }

    #[test]
    fn a_finding_names_a_place_only_when_the_models_agree_on_one() {
        assert_eq!(agreed(&[0.45, 0.55, 0.0]), Some(1));
        assert_eq!(agreed(&[0.4, 0.35, 0.25]), None, "no line has half");
    }
}
