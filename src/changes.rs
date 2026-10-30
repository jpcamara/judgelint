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
    LazyLock::new(|| Regex::new(r"\A@@ -[0-9]+(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@").unwrap());

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
        // No configured filter runs.
        "--no-textconv",
        "--relative",
        "--diff-filter=d",
        base.trim(),
    ])?;
    let mut changed = parse_diff(&diff);
    // A changed file with no lines in the diff, like one .gitattributes
    // marks binary, is changed throughout.
    let names = run(&["git", "diff", "--name-only", "-z", "--relative", "--diff-filter=d", base.trim()])?;
    for path in names.split('\0').filter(|p| !p.is_empty()) {
        changed.entry(path.to_string()).or_insert(Changed::All);
    }
    for path in run(&["git", "ls-files", "-z", "--others", "--exclude-standard"])?.split('\0').filter(|p| !p.is_empty())
    {
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

/// The changed lines in `git diff -U0` output. A file's name is read only
/// from its header, never from inside a hunk, where an added line could
/// look like one.
pub fn parse_diff(diff: &str) -> Changes {
    let mut changed: Changes = HashMap::new();
    let mut path: Option<String> = None;
    // The current hunk's lines still to come, removed and added.
    let (mut removed, mut added) = (0u32, 0u32);
    for line in diff.lines() {
        if removed > 0 || added > 0 {
            match line.as_bytes().first() {
                Some(b'-') => removed = removed.saturating_sub(1),
                Some(b'+') => added = added.saturating_sub(1),
                Some(b' ') => {
                    removed = removed.saturating_sub(1);
                    added = added.saturating_sub(1);
                }
                // "\ No newline at end of file"
                _ => {}
            }
            continue;
        }
        if line.starts_with("diff --git ") {
            path = None;
        } else if let Some(target) = line.strip_prefix("+++ ") {
            let target = unquote(target.trim_end_matches('\t'));
            path = (target != "/dev/null").then(|| target.strip_prefix("b/").unwrap_or(&target).to_string());
        } else if let Some(hunk) = HUNK.captures(line) {
            let count = |i: usize| hunk.get(i).map_or(1, |c| c.as_str().parse().unwrap_or(u32::MAX));
            (removed, added) = (count(1), count(3));
            let Some(path) = &path else { continue };
            let start: u32 = hunk[2].parse().unwrap_or(u32::MAX);
            // A pure deletion marks the line above the gap, so it's still judged.
            let lines = if added == 0 { start.max(1)..start.max(1) + 1 } else { start..start.saturating_add(added) };
            if let Changed::Lines(existing) = changed.entry(path.clone()).or_insert_with(|| Changed::Lines(Vec::new()))
            {
                existing.extend(lines);
            }
        }
    }
    changed
}

/// A path as git prints it, where one with a tab, newline, quote or
/// backslash is quoted with C escapes.
fn unquote(text: &str) -> String {
    let Some(inner) = text.strip_prefix('"').and_then(|t| t.strip_suffix('"')) else {
        return text.to_string();
    };
    let mut bytes = Vec::with_capacity(inner.len());
    let mut rest = inner.as_bytes();
    while let [first, tail @ ..] = rest {
        rest = tail;
        if *first != b'\\' {
            bytes.push(*first);
            continue;
        }
        let Some((&escaped, tail)) = rest.split_first() else { break };
        rest = tail;
        match escaped {
            b'0'..=b'7' => {
                let more = rest.iter().take(2).take_while(|d| (b'0'..=b'7').contains(*d)).count();
                let digits = std::iter::once(escaped).chain(rest[..more].iter().copied());
                bytes.push(digits.fold(0u8, |n, d| n.wrapping_mul(8).wrapping_add(d - b'0')));
                rest = &rest[more..];
            }
            b't' => bytes.push(b'\t'),
            b'n' => bytes.push(b'\n'),
            b'r' => bytes.push(b'\r'),
            b'a' => bytes.push(7),
            b'b' => bytes.push(8),
            b'f' => bytes.push(12),
            b'v' => bytes.push(11),
            other => bytes.push(other),
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn check_ref(reference: &str) -> Result<()> {
    if !REF.is_match(reference) || reference.contains("..") {
        bail!("Not a usable git ref: {reference}");
    }
    Ok(())
}

/// A commit's files, read from git rather than the working tree: the base
/// branch a pull request is checked against, whose rules, config and cache
/// the pull request can't change.
pub struct Commit {
    pub reference: String,
    /// Regular files under the working directory, as paths relative to it, sorted.
    files: Vec<String>,
}

impl Commit {
    pub fn new(reference: &str) -> Result<Commit> {
        check_ref(reference)?;
        let listing = run_bytes(&["git", "ls-tree", "-r", "-z", reference])?;
        let mut files: Vec<String> = listing
            .split(|&b| b == 0)
            .filter_map(|entry| {
                let entry = String::from_utf8_lossy(entry);
                let (meta, path) = entry.split_once('\t')?;
                // Plain and executable files; not links or submodules.
                (meta.starts_with("100644 blob") || meta.starts_with("100755 blob")).then(|| path.to_string())
            })
            .collect();
        files.sort_unstable();
        Ok(Commit { reference: reference.to_string(), files })
    }

    pub fn files(&self) -> &[String] {
        &self.files
    }

    /// A file's contents at the commit, or None when it has no such file.
    pub fn read(&self, path: &str) -> Result<Option<Vec<u8>>> {
        let path = path.strip_prefix("./").unwrap_or(path);
        if self.files.binary_search_by(|f| f.as_str().cmp(path)).is_err() {
            return Ok(None);
        }
        run_bytes(&["git", "cat-file", "blob", &format!("{}:./{path}", self.reference)]).map(Some)
    }

    pub fn read_text(&self, path: &str) -> Result<String> {
        match self.read(path)? {
            Some(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
            None => bail!("{path} isn't on {}", self.reference),
        }
    }
}

fn run(args: &[&str]) -> Result<String> {
    run_bytes(args).map(|out| String::from_utf8_lossy(&out).into_owned())
}

fn run_bytes(args: &[&str]) -> Result<Vec<u8>> {
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
    Ok(output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunks() {
        let diff = "+++ b/a.rb\n@@ -1,0 +2,2 @@\n+x\n+y\n@@ -9 +10,0 @@\n-z\n+++ /dev/null\n";
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

    #[test]
    fn an_added_line_that_looks_like_a_header_is_still_a_line() {
        let diff = concat!(
            "diff --git a/a.rb b/a.rb\n",
            "--- a/a.rb\n",
            "+++ b/a.rb\n",
            "@@ -2 +2,2 @@\n",
            "-old\n",
            "+++ b/../secret.txt\n",
            "+next\n",
            "@@ -55,0 +56 @@\n",
            "+SMELL\n",
        );
        let changed = parse_diff(diff);
        assert_eq!(changed.keys().collect::<Vec<_>>(), ["a.rb"]);
        assert_eq!(changed["a.rb"], Changed::Lines(vec![2, 3, 56]));
    }

    #[test]
    fn quoted_paths() {
        let diff = "+++ \"b/tab\\there \\\"q\\\" \\303\\251.rb\"\n@@ -0,0 +1 @@\n+x\n";
        assert_eq!(parse_diff(diff).keys().collect::<Vec<_>>(), ["tab\there \"q\" \u{e9}.rb"]);
    }
}
