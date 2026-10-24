# Changelog

## 0.1.1 (2026-10-23)

- `judgehint:` comments replace `judgelint:disable`. A hint explains why code
  breaks a rule. judgelint asks each rule whether the hint gives a reason that
  applies to it, and reports the finding as excused if it does.
- Each GitHub release has native binaries for macOS and Linux. Install them
  with Homebrew (`brew install jpcamara/tap/judgelint`) or `install.sh`.

## 0.1.0 (2026-10-23)

- Specs work the way praxis's do: a README or `*.judgelint.md` with `paths:`
  in its frontmatter, where each top-level bullet is a rule. The model reads
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
- `examples/scoop-society` runs judgelint on praxis's TypeScript demo and
  compares the results with praxis's.
