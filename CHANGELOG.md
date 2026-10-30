# Changelog

## 0.2.2 (unreleased)

Fixes from a third review of 0.2.1, which found ways around its fixes.

- `--pr` judges what the pull request committed. Untracked files, like ones
  an earlier CI step wrote, aren't part of it and are never sent, whatever
  the pull request's `.gitignore` says, and a tracked file a step changed is
  read as committed.
- `--pr` reads the base branch's cache into memory and leaves the
  checkout's `.judgelint/cache.bin` alone.
- `--base` and `--pr` work with `check` only. `judgelint test --pr` used to
  run, ignore `--pr`, and use the pull request's config.
- Under `--base` or `--pr`, these now fail the run instead of passing:
  - a changed file with a NUL byte near its start, which counted as binary
    and was left out (images, fonts, archives and other formats that are
    never code are still left out);
  - a rule the model refused to answer for one window when another passed;
  - a changed file that leads outside the project, or to nothing.
- Deleting or moving a file asks about its directory's directory rules.
- An empty file is asked about by rules about whole files and directories.
- If git fails to list the project's files, that's an error. Before, the
  gitignore check was skipped and ignored files could be sent.
- The project's `.judgelint.yml` must be a regular file inside the project,
  1 MB at most. A config named with `--config` can be anywhere.
- Files are opened with no links allowed in the path, so a directory
  swapped for a link while judgelint runs can't lead it outside.
- Runs that share a cache no longer drop each other's answers.
- A custom endpoint's answers are cached under the address and headers its
  `${VAR}`s resolve to. Custom endpoints, and presets with headers,
  ask again once.
- A failed request stops the run: no more requests go out, from that file
  or any other.
  Requests go out 32 at a time across files. Responses are capped at 4 MB.
- A file too large for every model is skipped before its questions are
  made, and a directory's files are capped at 4 MB together.
- Control characters in file names and endpoint errors are escaped in
  output, and so are GitHub workflow commands (a leading `::`, or `##[`), so
  they can't forge a CI annotation.
- A header whose `${VAR}` isn't set is an error; it was sent as written.
  The key's header is marked sensitive. `price_per_million` can't be
  negative. Cached choices must add up to one. YAML is parsed with
  explicit limits.
- CI runs cargo-deny and zizmor, builds with the oldest supported Rust,
  and builds the binaries with cargo-auditable. Dependabot updates the
  actions and crates. install.sh checks the build attestation, for the
  release's tag and workflow, when the GitHub CLI is signed in.

## 0.2.1 (2026-10-29)

Security fixes, after two reviews of 0.2.0. A pull request could change the
config or specs to send code and environment variables to its own server,
read files outside the project, or pass with answers it made up.

- `--pr` reads `.judgelint.yml`, the specs and the cache from the base
  branch, not the pull request.
- Every file sent to a model, including `context:` files and a directory
  rule's files, must be inside the project, not reached through a link that
  leaves it, not ignored by git, not binary, and at most 4 MB.
- A provider pointed at another `api_base` doesn't get the provider's key;
  set `api_key_env` for it. Its answers are cached apart.
- Plain http goes only to localhost. Redirects aren't followed. Responses
  are capped at 16 MB, and a request at 60 seconds.
- Under `--base` or `--pr`, a changed file that's skipped or refused fails
  the run.
- An added line that looks like a diff header no longer hides changed lines.
- Malformed answers and cached values that aren't probabilities are errors
  or misses, not passes.
- A model with no price fails the cost check unless you pass `--yes` or set
  `price_per_million`. Servers on localhost cost nothing.
- Errors show the URL as configured, before `${VAR}` is filled in.
- Releases carry build attestations, are built with a pinned Rust, and push
  the gems from CI. The gem no longer replaces its command with a link to the
  binary, which could break after an uninstall.

## 0.2.0 (2026-10-28)

- judgelint is written in Rust now. The gem carries the binary for macOS and
  Linux on arm64 and x86_64. On any other platform the gem says how to build
  it with Cargo; it no longer runs as plain Ruby. There's no Ruby API.
- It's much faster and smaller than 0.1.10's native binary. On a Mac mini:

  | Run | 0.1.10 | 0.2.0 |
  |---|---|---|
  | Plan 50,000 files | 9.0 s, 140 MB | 1.2 s, 54 MB |
  | Check 5,000 files, nothing cached | 3.4 s, 82 MB | 0.7 s, 19 MB |
  | Check 5,000 files, all cached | 1.5 s, 56 MB | 0.16 s, 16 MB |
  | Check 50,000 files, nothing cached | 23.8 s, 487 MB | 6.4 s, 75 MB |

- Answers are cached in `.judgelint/cache.bin`. The old `cache.json` isn't
  read, so the first run asks again; delete it afterward. The new cache is
  about a quarter of the size.
- Commands, options, specs, config and output formats are the same. Error
  messages are worded differently.

## 0.1.10 (2026-10-27)

- `check` and `test` use far less memory and run faster. Against 0.1.9 on
  a synthetic project, the native binary uses 84–89% less memory, and
  Ruby 73–87% less. Both are 23–51% faster.
  - Files of the same shape share their questions.
  - A planned file is read again when its request is sent instead of being
    kept. A file that changed in between stops the run with an error.
  - The cache stays on disk and is looked up an entry at a time.
  - Connections to the model are kept open between requests.
  - Each glob pattern is walked once.
- Output and cache files are unchanged.

## 0.1.9 (2026-10-27)

- `check` uses much less memory on large projects. On 50,000 files its
  peak falls from 835 MB to 518 MB in Ruby and from 2.25 GB to 856 MB in
  the native binary. Output is unchanged.

## 0.1.8 (2026-10-26)

- YAML that names a class `safe_load` won't build, like `!ruby/sym` or a
  date, is a config error instead of a crash with a stack trace. So are
  YAML aliases.

## 0.1.7 (2026-10-26)

- A symlink that points to itself no longer crashes a run. Ruby's Dir.glob
  raised ELOOP when a pattern looked inside one; judgelint now skips it.

## 0.1.6 (2026-10-26)

- `--base` and `--pr` ask about the changed lines, not the 40-line windows
  around them. A finding the model places on a line the change didn't touch
  doesn't count, so editing an old file can't fail it for code the edit
  left alone.

## 0.1.5 (2026-10-26)

- The text report is in color in a terminal: errors in red, warnings and
  uncertain findings in yellow, and file names in bold. `judgelint test`
  marks hits green and misses red. `NO_COLOR` turns color off and
  `FORCE_COLOR` turns it on. Piped output is unchanged.

## 0.1.4 (2026-10-24)

- `Bad:` and `Good:` code blocks under a bullet are examples. The model reads
  them with the spec, and `judgelint test` judges each one, along with the
  files in `.judgelint/examples/`.
- `judgelint init` writes a `CONVENTIONS.md` with examples in it.
- `examples/conventions` has complete specs for Ruby, TypeScript, Python, and
  Postgres migrations.

## 0.1.3 (2026-10-24)

- No setup beyond `TYPESAFE_API_KEY`. A `CONVENTIONS.md` of bullets is a
  spec with no frontmatter, and it covers the files in its directory and
  below, except Markdown and lockfiles. A README still needs `paths:`.
- The cost line names the model.
- Full runs skip files git ignores, and binary files.
- `judgelint init` no longer writes `.judgelint.yml`.
- A run the cache answers in full needs no API key.

## 0.1.2 (2026-10-24)

- Each bullet is one choice between breaking the rule, following it, and the
  rule not applying, in place of two yes/no questions. On the demo app, Jev
  finds 13 of 14 known violations, up from 12, with half the questions.
- Findings name the line that breaks the rule, or the file in a directory,
  when the model is sure of one.
- Both the System One and OpenAI Decisions protocols send choice questions.

## 0.1.1 (2026-10-23)

- `judgehint:` comments replace `judgelint:disable`. A hint explains why code
  breaks a rule. judgelint asks each rule whether the hint gives a reason that
  applies to it, and reports the finding as excused if it does.
- Each GitHub release has native binaries for macOS and Linux. Install them
  with Homebrew (`brew install jpcamara/tap/judgelint`) or `install.sh`.

## 0.1.0 (2026-10-23)

- Specs: a README or `*.judgelint.md` with `paths:` in its frontmatter,
  where each top-level bullet is a rule. The model reads
  the spec with the file, and each bullet is asked both ways and averaged.
  `violation:` and `compliant:` lines under a bullet describe it more
  precisely. Rules that don't fit in a bullet can be written as questions in
  `.judgelint/rules/`.
- Rules can apply to every 40 lines, a whole file, or a whole directory.
  `context:` adds files the model reads but doesn't judge.
- Commands: `check`, `test`, `rules`, `providers`, and `init`. `--base` and
  `--pr` check only what changed. Output as text, JSON, GitHub annotations,
  or SARIF.
- Requests are planned and priced before any are sent, and `max_cost_usd`
  stops an expensive run. Every run prints its cost, and answers are cached
  per model.
- 16 providers over the System One and OpenAI Decisions APIs. List more than
  one in `models:` to average their answers.
- `judgelint:disable` comments, with a required reason.
- No runtime dependencies. The macOS and Linux gems include a native binary
  built with Spinel.
- `examples/scoop-society`, a TypeScript demo app with known violations.
