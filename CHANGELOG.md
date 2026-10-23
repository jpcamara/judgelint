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
