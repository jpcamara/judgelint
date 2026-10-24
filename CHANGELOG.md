# Changelog

## 0.1.1 (2026-10-23)

- `judgehint:` comments replace `judgelint:disable`. A hint says why the code
  is the way it is; each rule asks whether it gives a reason the code may
  break that rule, and reports the finding as excused if so.
- Native binaries for macOS and Linux on each GitHub release, installable
  with Homebrew (`brew install jpcamara/tap/judgelint`) or `install.sh`.

## 0.1.0 (2026-10-23)

- Specs as praxis reads them: a README (or `*.judgelint.md`) with `paths:`
  frontmatter, each top-level bullet a rule. The model reads the spec's prose
  with the file and is asked whether the code breaks each bullet and whether
  it follows it; optional `violation:` and `compliant:` lines sharpen a
  bullet. Question rules in `.judgelint/rules/` for conventions a bullet
  can't carry.
- Window, file, and directory scopes; `context:` files the model reads but
  never judges; line ranges on findings.
- `check`, `test` (examples under `.judgelint/examples/`), `rules`,
  `providers`, and `init`; `--base` and `--pr` for changes; text, JSON,
  GitHub annotations, and SARIF.
- Every request planned and priced before it's sent, with `max_cost_usd`; a
  cost line on every run; answers cached per model.
- 16 provider presets over the System One and OpenAI Decisions protocols, and
  `models:` to average several.
- Inline `judgelint:disable` comments, with a required reason.
- No runtime dependencies; platform gems for macOS and Linux carry a native
  binary built with Spinel.
- examples/scoop-society: praxis's TypeScript demo, checked against praxis's
  verdicts.
