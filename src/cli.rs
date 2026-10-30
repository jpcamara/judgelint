//! Command line entry point. Exit codes: 0 clean, 1 violations (or missed
//! examples for `test`), 2 usage or configuration error. Everything that can
//! be checked is checked before the first paid request.

use std::io::{self, IsTerminal, Write};
use std::sync::Arc;
use std::thread::JoinHandle;

use anyhow::{Context, Result, anyhow, bail};
use clap::{Arg, ArgAction, CommandFactory, FromArgMatches, Parser, Subcommand};
use rayon::prelude::*;

use crate::cache::Cache;
use crate::changes::{self, Changed, Changes, Commit};
use crate::client::Client;
use crate::config::{self, Config};
use crate::glob::{self, Contents, Patterns};
use crate::paint::{self, Paint};
use crate::providers;
use crate::reporter::{Format, Reporter};
use crate::rule::Rule;
use crate::runner::{Job, Runner};
use crate::spec;
use crate::usage::{self, Usage};
use crate::verdict::{Status, Verdict};

/// Checks code against the conventions in your specs, like a CONVENTIONS.md
/// of bullets. For each file and each rule, it asks a decision model (Jev on
/// TypeSafe by default) whether the code breaks it.
#[derive(Parser)]
#[command(
    name = "judgelint",
    version,
    args_override_self = true,
    after_help = "Exit status: 0 clean, 1 violations or missed examples, 2 usage or config error."
)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,
    /// Files or directories to check
    paths: Vec<String>,
    #[command(flatten)]
    options: Options,
}

#[derive(Subcommand)]
enum Command {
    /// Check the files the specs govern, or these (the default)
    Check { paths: Vec<String> },
    /// Judge each rule's examples (.judgelint/examples/<id>/pass and fail) and
    /// report what the model gets wrong
    Test { rules: Vec<String> },
    /// List the rules and how many files each governs
    Rules,
    /// List the decision-model providers judgelint knows
    Providers,
    /// Write a CONVENTIONS.md to start from, with examples
    Init,
}

#[derive(clap::Args)]
struct Options {
    /// Check only what changed since the merge base with REF, uncommitted work included
    #[arg(long, value_name = "REF", global = true, conflicts_with = "pr")]
    base: Option<String>,
    /// --base the pull request's base branch, from CI variables or the gh CLI
    #[arg(long, global = true)]
    pr: bool,
    #[arg(short, long, value_enum, default_value_t = Format::Text, global = true)]
    format: Format,
    /// Ask this model instead of the config's: a provider from `judgelint
    /// providers`, optionally :model (cloudflare:clef)
    #[arg(short, long, global = true)]
    model: Option<String>,
    /// Config file (default .judgelint.yml)
    #[arg(short, long, value_name = "PATH", global = true)]
    config: Option<String>,
    /// Ask the models even when an answer is cached
    #[arg(long, global = true)]
    no_cache: bool,
    /// Run even past max_cost_usd
    #[arg(short, long, global = true)]
    yes: bool,
}

pub fn main() -> i32 {
    let version = Arg::new("version").short('v').long("version").action(ArgAction::Version).help("Print the version");
    let command = Args::command().disable_version_flag(true).arg(version);
    let args = Args::from_arg_matches(&command.get_matches()).unwrap_or_else(|e| e.exit());
    let mut app = App {
        out: io::BufWriter::new(io::stdout()),
        paint: Paint::for_stream(io::stdout().is_terminal()),
        err_paint: Paint::for_stream(io::stderr().is_terminal()),
        usage: None,
        models: String::new(),
        options: args.options,
    };
    let result = match args.command {
        None => app.check(args.paths),
        Some(Command::Check { paths }) => app.check([args.paths, paths].concat()),
        Some(Command::Test { rules }) => app.test(rules),
        Some(Command::Rules) => app.list_rules(),
        Some(Command::Providers) => app.list_providers(),
        Some(Command::Init) => app.init(),
    };
    let status = result.unwrap_or_else(|e| {
        let _ = app.out.flush();
        eprintln!("{} {e:#}", app.err_paint.call("judgelint:", paint::BOLD_RED));
        // Requests that succeeded before the failure are still billed.
        if app.usage.as_ref().is_some_and(|u| u.requests() > 0) {
            app.cost_line();
        }
        2
    });
    let _ = app.out.flush();
    status
}

struct App {
    options: Options,
    out: io::BufWriter<io::Stdout>,
    paint: Paint,
    err_paint: Paint,
    usage: Option<Arc<Usage>>,
    models: String,
}

impl App {
    fn check(&mut self, paths: Vec<String>) -> Result<i32> {
        let base = if self.options.pr { Some(changes::pr_base()?) } else { self.options.base.clone() };
        // A pull request is checked against its base branch's rules, config
        // and cache, so it can't change what it's checked against.
        let trusted = match (&base, self.options.pr) {
            (Some(base), true) => Some(Commit::new(base)?),
            _ => None,
        };
        if let Some(commit) = trusted.as_ref().filter(|_| !self.options.no_cache) {
            use_cache_from(commit)?;
        }
        let loading = self.load_cache_early();
        let (config, rules) = self.load_rules(trusted.as_ref())?;
        let changes = base.as_deref().map(changes::since).transpose()?;
        let candidates = check_paths(&rules, &paths, changes.as_ref())?;
        if !rules.iter().any(|r| r.is_directory() || !r.context.is_empty()) {
            glob::release();
        }
        let runner = Runner::new(&config, &rules);
        // A file no rule governs, that's ignored, or that's binary is left
        // out, and so is one judgelint won't send, with a warning. Checking a
        // change, that one is skipped instead, which fails the run.
        let prepare = |path: &String| -> Result<Option<Vec<Job>>> {
            if config.ignore.is_match(path) || !rules.iter().any(|r| !r.is_directory() && r.applies_to(path)) {
                return Ok(None);
            }
            let text = match glob::read_to_send(path)? {
                Contents::Text(text) => text,
                Contents::Binary | Contents::Ignored => return Ok(None),
                Contents::TooLarge => return runner.skip_file(path).map(Some),
                Contents::Excluded(why) => {
                    eprintln!("judgelint: left out {why}");
                    return if changes.is_some() { runner.skip_file(path).map(Some) } else { Ok(None) };
                }
            };
            let lines = changes.as_ref().map_or(Some(&Changed::All), |c| c.get(path.as_str()));
            runner.prepare_file(path, text, lines).map(Some)
        };
        let mut files = 0;
        let mut jobs = Vec::with_capacity(candidates.len());
        // A chunk at a time, so a run holds its jobs once.
        for chunk in candidates.chunks(4096) {
            let prepared: Vec<Result<Option<Vec<Job>>>> = chunk.par_iter().map(prepare).collect();
            for found in prepared {
                if let Some(found) = found? {
                    files += 1;
                    jobs.extend(found);
                }
            }
        }
        drop(candidates);
        let directories: Vec<String> =
            check_directories(&rules, &paths)?.into_iter().filter(|d| !config.ignore.is_match(d)).collect();
        let (clients, cache) = self.runner_parts(&config, loading)?;
        jobs.extend(runner.plan_directories(&directories, changes.as_ref())?);
        glob::release();
        runner.pack_all(&mut jobs, &clients, &cache)?;
        runner.check_keys(&jobs, &clients)?;
        self.guard_cost(&config, &runner, &jobs, &clients)?;
        runner.execute(&mut jobs, &clients, &cache)?;
        let verdicts: Vec<&Verdict> = jobs.iter().flat_map(Job::verdicts).collect();
        let usage = self.usage.clone().unwrap_or_default();
        Reporter::new(&mut self.out, self.options.format, self.paint, &rules).check(
            &verdicts,
            &config,
            files + directories.len(),
            &usage,
        )?;
        self.cost_line();
        // Checking a change, a file that couldn't be judged fails too.
        let unjudged = verdicts
            .iter()
            .filter(|v| matches!(v.status, Status::Skipped | Status::Refused) && rules[v.rule].is_error())
            .count();
        if changes.is_some() && unjudged > 0 {
            eprintln!("judgelint: {unjudged} checks of changed files were skipped or refused, so the run fails");
            return Ok(1);
        }
        Ok(i32::from(verdicts.iter().any(|v| v.failing(&rules))))
    }

    fn test(&mut self, ids: Vec<String>) -> Result<i32> {
        let loading = self.load_cache_early();
        let (config, mut rules) = self.load_rules(None)?;
        if !ids.is_empty() {
            let unknown: Vec<&str> =
                ids.iter().filter(|id| !rules.iter().any(|r| &r.id == *id)).map(String::as_str).collect();
            if !unknown.is_empty() {
                bail!("Unknown rules: {}", unknown.join(", "));
            }
            rules.retain(|r| ids.contains(&r.id));
        }
        let (clients, cache) = self.runner_parts(&config, loading)?;
        let mut runner = Runner::new(&config, &rules);
        let mut jobs = runner.plan_examples()?;
        glob::release();
        runner.pack_all(&mut jobs, &clients, &cache)?;
        if jobs.is_empty() {
            let dir = rules.first().map_or("", |r| r.examples_dir.as_str());
            bail!("No rule has examples yet. Add some under {dir}/{{pass,fail}}/");
        }
        if !runner.untested.is_empty() {
            let ids: Vec<&str> = runner.untested.iter().map(|&i| rules[i].id.as_str()).collect();
            let has = if ids.len() == 1 { "rule has" } else { "rules have" };
            eprintln!("{} {has} no examples: {}", ids.len(), ids.join(", "));
        }
        runner.check_keys(&jobs, &clients)?;
        self.guard_cost(&config, &runner, &jobs, &clients)?;
        runner.execute(&mut jobs, &clients, &cache)?;
        let examples: Vec<&Verdict> = jobs.iter().flat_map(Job::verdicts).collect();
        let usage = self.usage.clone().unwrap_or_default();
        Reporter::new(&mut self.out, self.options.format, self.paint, &rules).fixtures(&examples, &usage)?;
        self.cost_line();
        Ok(i32::from(!examples.iter().all(|e| e.correct())))
    }

    /// Prices the planned requests and refuses a run over max_cost_usd, or
    /// one it can't price.
    fn guard_cost(&self, config: &Config, runner: &Runner, jobs: &[Job], clients: &[Client]) -> Result<()> {
        if self.options.yes {
            return Ok(());
        }
        let Some(estimate) = runner.estimated_cost(jobs, clients) else {
            let unpriced: Vec<String> =
                clients.iter().filter(|c| c.endpoint.price_per_million.is_none()).map(|c| c.endpoint.label()).collect();
            bail!(
                "This run would send {} requests to {}, which has no price, so max_cost_usd can't be checked. \
                 Set its price_per_million in .judgelint.yml, or pass --yes to run it anyway.",
                runner.request_count(jobs),
                unpriced.join(", ")
            );
        };
        if estimate <= config.max_cost_usd {
            return Ok(());
        }
        bail!(
            "This run would send {} requests, about {} input tokens (${estimate:.2}), over max_cost_usd (${:.2}). Pass --yes to run it anyway.",
            runner.request_count(jobs),
            usage::delimit(runner.estimated_tokens(jobs) as u64),
            config.max_cost_usd
        )
    }

    /// What the run cost, and which models answered.
    fn cost_line(&self) {
        if let Some(usage) = &self.usage {
            eprintln!("{}", self.err_paint.call(&format!("{}, {}", usage.line(), self.models), paint::DIM));
        }
    }

    fn list_rules(&mut self) -> Result<i32> {
        let (_config, rules) = self.load_rules(None)?;
        for rule in &rules {
            let count = if rule.is_directory() {
                format!("{} dirs", rule.directories()?.len())
            } else {
                format!("{} files", glob::files(&rule.paths)?.iter().filter(|p| rule.applies_to(p)).count())
            };
            let text = rule.question.as_deref().unwrap_or(&rule.message);
            writeln!(self.out, "{:<24} {:<8} {count:>10}  {text}", rule.id, rule.severity())?;
        }
        Ok(0)
    }

    fn list_providers(&mut self) -> Result<i32> {
        for preset in providers::all() {
            let model = preset.model.as_deref().unwrap_or("(you choose)");
            let key = preset.api_key_env.as_deref().unwrap_or("no key");
            let base = preset.api_base.as_deref().unwrap_or("(your endpoint)");
            writeln!(self.out, "{:<13} {model:<28} {key:<22} {base}", preset.name)?;
            if let Some(needs) = &preset.needs {
                writeln!(self.out, "              needs {needs}")?;
            }
        }
        Ok(0)
    }

    fn init(&mut self) -> Result<i32> {
        let path = "CONVENTIONS.md";
        if std::path::Path::new(path).exists() {
            writeln!(self.out, "exists  {path}")?;
        } else {
            std::fs::write(path, include_str!("conventions.md"))?;
            writeln!(self.out, "create  {path}")?;
        }
        eprintln!("Next: set TYPESAFE_API_KEY, then run `judgelint test` to see the examples judged.");
        Ok(0)
    }

    fn load_rules(&self, commit: Option<&Commit>) -> Result<(Config, Vec<Rule>)> {
        let config = Config::load(self.options.config.as_deref(), self.options.model.as_deref(), commit)?;
        let rules = spec::discover(config.threshold, &config.ignore, commit)?;
        Ok((config, rules))
    }

    /// Starts reading the cache's index while the files are found and read.
    fn load_cache_early(&self) -> Option<JoinHandle<Result<Cache>>> {
        let wanted = !self.options.no_cache && std::path::Path::new(config::CACHE).is_file();
        wanted.then(|| std::thread::spawn(|| Cache::open(Some(config::CACHE))))
    }

    fn runner_parts(
        &mut self,
        config: &Config,
        loading: Option<JoinHandle<Result<Cache>>>,
    ) -> Result<(Vec<Client>, Cache)> {
        let usage = Arc::new(Usage::default());
        self.usage = Some(usage.clone());
        self.models = config.label();
        let clients =
            config.models.iter().map(|e| Client::new(e.clone(), usage.clone())).collect::<Result<Vec<_>>>()?;
        let cache = match loading {
            Some(loading) => loading.join().map_err(|_| anyhow!("Couldn't read the cache"))??,
            None => Cache::open((!self.options.no_cache).then_some(config::CACHE))?,
        };
        Ok((clients, cache))
    }
}

/// Puts the commit's cache in place of the working tree's, or none when it
/// has none: answers a pull request brings along could say anything.
fn use_cache_from(commit: &Commit) -> Result<()> {
    let path = std::path::Path::new(config::CACHE);
    let dir = path.parent().unwrap_or(std::path::Path::new("."));
    if dir.symlink_metadata().is_ok_and(|m| !m.is_dir()) {
        bail!("{} isn't a directory; judgelint keeps its cache in one", dir.display());
    }
    let replace = || -> std::io::Result<()> {
        match commit.read(config::CACHE).map_err(std::io::Error::other)? {
            Some(bytes) => {
                std::fs::create_dir_all(dir)?;
                let temporary = format!("{}.{}.tmp", config::CACHE, std::process::id());
                let _ = std::fs::remove_file(&temporary);
                std::fs::OpenOptions::new().write(true).create_new(true).open(&temporary)?.write_all(&bytes)?;
                // A rename replaces a link itself, never what it points to.
                std::fs::rename(&temporary, path)
            }
            None if path.symlink_metadata().is_ok() => std::fs::remove_file(path),
            None => Ok(()),
        }
    };
    replace().with_context(|| format!("Couldn't put {}'s {} in place", commit.reference, config::CACHE))
}

/// The files to check, before the ignored and binary ones are left out.
fn check_paths(rules: &[Rule], paths: &[String], changes: Option<&Changes>) -> Result<Vec<String>> {
    if !paths.is_empty() {
        let found = glob::expand_arguments(paths)?;
        let missing: Vec<&str> = found.iter().filter(|p| !glob::is_file(p)).map(String::as_str).collect();
        if !missing.is_empty() {
            bail!("No such file: {}", missing.join(", "));
        }
        return Ok(match changes {
            Some(changes) => found.into_iter().filter(|p| changes.contains_key(p)).collect(),
            None => found,
        });
    }
    if let Some(changes) = changes {
        let mut changed: Vec<String> = changes.keys().filter(|p| glob::is_file(p)).cloned().collect();
        changed.sort_unstable();
        return Ok(changed);
    }
    let mut patterns: Vec<String> = Vec::new();
    for pattern in rules.iter().flat_map(|r| &r.paths.raw) {
        if !patterns.contains(pattern) {
            patterns.push(pattern.clone());
        }
    }
    glob::files(&Patterns::new(patterns)?)
}

/// The directories directory rules govern; with paths named, those the
/// paths are in or are. With a change, the runner keeps those it touched.
fn check_directories(rules: &[Rule], paths: &[String]) -> Result<Vec<String>> {
    let mut directories = Vec::new();
    for rule in rules.iter().filter(|r| r.is_directory()) {
        directories.extend(rule.directories()?);
    }
    directories.sort_unstable();
    directories.dedup();
    if paths.is_empty() {
        return Ok(directories);
    }
    let named: Vec<&str> = paths.iter().map(|p| p.strip_prefix("./").unwrap_or(p).trim_end_matches('/')).collect();
    let within = |inner: &str, outer: &str| inner.strip_prefix(outer).is_some_and(|rest| rest.starts_with('/'));
    directories.retain(|dir| named.iter().any(|path| path == dir || within(path, dir) || within(dir, path)));
    Ok(directories)
}
