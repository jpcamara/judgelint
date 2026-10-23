# Changelog

## 0.1.0 (unreleased)

- First version: `check`, `test`, `rules`, and `init` commands; markdown rules
  with yes/no questions; a System One client with no runtime dependencies; answer cache;
  text and JSON output; native binary through Spinel.
- Presets for 16 decision-model providers, both the System One and OpenAI
  Decisions protocols, configurable path, auth, headers, and `${VAR}` in URLs,
  Cloudflare's response envelope, refusals, retries, and `judgelint providers`.
- Platform gems for macOS and Linux carry a statically linked native binary,
  which `judgelint` runs when it's there.
- Line ranges: the model sees the whole numbered file and a question per rule
  and window, and each finding names its lines. `scope: file` for rules about
  the whole file.
- `--base REF` and `--pr` check only the windows a change touched.
- Every request is planned first: files over the token budget are skipped,
  questions are packed into requests, and runs over `max_cost_usd` or
  `full_run_limit` need `--yes`. Each run prints its requests, tokens, and cost.
- `judgelint test` requires pass and fail examples for every rule.
- `scope: directory` judges each directory a rule's paths match as one unit,
  for conventions about how files relate, and `context:` sends files the
  model reads but never judges.
- examples/scoop-society: praxis's TypeScript demo with its three specs as
  rules, checked against praxis's verdicts from a committed cache.
- `repeat`, `threads`, retries on connection errors, inline
  `judgelint:disable` comments with a required reason, and `--format github`
  and `--format sarif`.
