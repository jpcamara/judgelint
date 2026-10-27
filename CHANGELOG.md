# Changelog

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
