//! The lines a change touched, from git: everything since the merge base with
//! a ref, uncommitted work included. Old code outside the change isn't asked
//! about, so it can't block new work.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::sync::LazyLock;

use anyhow::{Result, bail};
use regex::Regex;

/// The lines changed in a file, or all of it for a new file.
#[derive(Clone, Debug, PartialEq)]
pub enum Changed {
    All,
    Lines(Vec<u32>),
}

pub type Changes = HashMap<String, Changed>;

/// A branch, tag, or commit (HEAD~1 too), and nothing git could read as an
/// option or a range.
static REF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\A[A-Za-z0-9][A-Za-z0-9._/~^-]*\z").unwrap());
static HUNK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\A@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@").unwrap());

/// CI variables that name a pull request's base branch.
const BASE_BRANCH_VARIABLES: [&str; 6] = [
    "JUDGELINT_BASE_BRANCH",
    "GITHUB_BASE_REF",
    "CI_MERGE_REQUEST_TARGET_BRANCH_NAME",
    "BUILDKITE_PULL_REQUEST_BASE_BRANCH",
    "BITBUCKET_PR_DESTINATION_BRANCH",
    "SYSTEM_PULLREQUEST_TARGETBRANCH",
];

/// Every line changed since the merge base with +reference+.
pub fn since(reference: &str) -> Result<Changes> {
    check_ref(reference)?;
    let base = run(&["git", "merge-base", reference, "HEAD"])?;
    let diff = run(&[
        "git",
        "-c",
        "core.quotePath=false",
        "diff",
        "-U0",
        "--no-color",
        "--no-ext-diff",
        "--relative",
        "--diff-filter=d",
        base.trim(),
    ])?;
    let mut changed = parse_diff(&diff);
    for path in run(&["git", "ls-files", "--others", "--exclude-standard"])?.lines() {
        changed.insert(path.to_string(), Changed::All);
    }
    Ok(changed)
}

/// The pull request's base branch, fetched, as origin/<branch>: from
/// JUDGELINT_BASE_BRANCH, then GitHub Actions, GitLab, Buildkite, Bitbucket,
/// or Azure Pipelines, then the gh CLI.
pub fn pr_base() -> Result<String> {
    let from_ci = BASE_BRANCH_VARIABLES.iter().find_map(|name| {
        // Buildkite sets "false" outside a pull request; Azure names a full ref.
        let value = std::env::var(name).unwrap_or_default();
        let branch = value.strip_prefix("refs/heads/").unwrap_or(&value).to_string();
        (!branch.is_empty() && branch != "false").then_some(branch)
    });
    let branch = match from_ci {
        Some(branch) => branch,
        None => run(&["gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName"])?.trim().to_string(),
    };
    if branch.is_empty() {
        bail!("Couldn't find the pull request's base branch");
    }
    check_ref(&branch)?;
    run(&["git", "fetch", "--no-tags", "--quiet", "origin", &branch])?;
    Ok(format!("origin/{branch}"))
}

pub fn parse_diff(diff: &str) -> Changes {
    let mut changed: Changes = HashMap::new();
    let mut path: Option<String> = None;
    for line in diff.lines() {
        if let Some(target) = line.strip_prefix("+++ ") {
            let target = target.trim_end_matches('\t');
            path = (target != "/dev/null").then(|| target.strip_prefix("b/").unwrap_or(target).to_string());
        } else if let (Some(path), Some(hunk)) = (&path, HUNK.captures(line)) {
            let start: u32 = hunk[1].parse().unwrap_or(u32::MAX);
            let count: u32 = hunk.get(2).map_or(1, |c| c.as_str().parse().unwrap_or(u32::MAX));
            // A pure deletion marks the line above the gap, so it's still judged.
            let lines = if count == 0 { start.max(1)..start.max(1) + 1 } else { start..start.saturating_add(count) };
            if let Changed::Lines(existing) = changed.entry(path.clone()).or_insert_with(|| Changed::Lines(Vec::new()))
            {
                existing.extend(lines);
            }
        }
    }
    changed
}

fn check_ref(reference: &str) -> Result<()> {
    if !REF.is_match(reference) || reference.contains("..") {
        bail!("Not a usable git ref: {reference}");
    }
    Ok(())
}

fn run(args: &[&str]) -> Result<String> {
    let output = Command::new(args[0])
        .args(&args[1..])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| anyhow::anyhow!("Couldn't run {}: {e}", args[0]))?;
    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        let first = err.trim().lines().next().unwrap_or("").trim().to_string();
        bail!("{} failed: {first}", args[..3.min(args.len())].join(" "));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunks() {
        let diff = "+++ b/a.rb\n@@ -1,0 +2,2 @@\n+x\n@@ -9 +10,0 @@\n+++ /dev/null\n";
        assert_eq!(parse_diff(diff).get("a.rb"), Some(&Changed::Lines(vec![2, 3, 10])));
    }

    #[test]
    fn files_in_a_diff() {
        let diff = concat!(
            "diff --git a/app/a.rb b/app/a.rb\n",
            "--- a/app/a.rb\n",
            "+++ b/app/a.rb\n",
            "@@ -3 +3 @@ class A\n",
            "-  old\n",
            "+  new\n",
            "@@ -10,2 +10,0 @@ class A\n",
            "-  gone\n",
            "-  gone\n",
            "@@ -20,0 +19,3 @@ class A\n",
            "+  one\n",
            "+  two\n",
            "+  three\n",
            "diff --git a/app/with space.rb b/app/with space.rb\n",
            "new file mode 100644\n",
            "--- /dev/null\n",
            "+++ b/app/with space.rb\t\n",
            "@@ -0,0 +1,2 @@\n",
            "+x\n",
            "+y\n",
            "diff --git a/top.rb b/top.rb\n",
            "--- a/top.rb\n",
            "+++ b/top.rb\n",
            "@@ -1 +0,0 @@\n",
            "-only line\n",
        );
        let changed = parse_diff(diff);
        assert_eq!(changed["app/a.rb"], Changed::Lines(vec![3, 10, 19, 20, 21]));
        assert_eq!(changed["app/with space.rb"], Changed::Lines(vec![1, 2]));
        assert_eq!(changed["top.rb"], Changed::Lines(vec![1]), "a deletion at the top marks line 1");
    }

    #[test]
    fn refs_git_could_read_as_options_or_ranges() {
        for good in ["main", "origin/main", "v1.2.0", "feature/x-y", "HEAD~1", "HEAD^", "3f2a9c1"] {
            assert!(check_ref(good).is_ok(), "{good}");
        }
        for bad in ["-x", "--upload-pack=x", "a..b", "a b", ""] {
            assert!(check_ref(bad).is_err(), "{bad}");
        }
    }
}
