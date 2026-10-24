# judgelint

judgelint checks code against conventions written in plain English. You write
them as bullets in a README. judgelint asks a decision model, such as
TypeSafe's Jev, whether each file breaks each bullet, and reports violations
with line numbers and an exit code like any other linter. Each answer takes a
few hundred milliseconds and costs a fraction of a cent.

## Install

```sh
brew install jpcamara/tap/judgelint
# or
curl -fsSL https://raw.githubusercontent.com/jpcamara/judgelint/main/install.sh | sh
```

The script installs to `~/.local/bin`, or to `$JUDGELINT_INSTALL_DIR`. The
binaries are on the [releases page](https://github.com/jpcamara/judgelint/releases)
for macOS and Linux, on arm64 and x86_64. Linux needs glibc 2.35 or newer
(Ubuntu 22.04, Debian 12). `gem install judgelint` works too, and runs as
plain Ruby on Windows.

## Getting started

```sh
judgelint init            # writes .judgelint.yml and an example spec
export TYPESAFE_API_KEY=...
judgelint test            # checks the example spec against its examples
judgelint                 # checks every file a spec covers
judgelint --base main     # checks only what changed since main
```

Here's a run on the [demo app](examples/scoop-society), with the messages shortened:

```text
$ judgelint src/services/apply-refund.ts src/features/flavor-of-day
src/services/apply-refund.ts
  x error      src/services/domain-failures-are-values-never-exceptions  1-21    0.95  Domain failures are values, never exceptions.
  x error      src/services/error-messages-are-written-for-the           1-21    0.94  Error messages are written for the API consumer.
  x error      src/services/every-service-has-a-doc-comment              1-21    0.97  Every service has a doc comment …
src/features/flavor-of-day
  x error      src/features/exactly-one-entry-point-index-ts                     0.81  Exactly one entry point, `index.ts`, …
  x error      src/features/logic-files-are-verb-first-kebab                     0.87  Logic files are verb-first kebab-case …
  ? uncertain  src/features/no-orphaned-files                                    0.60  No orphaned files.
  ? uncertain  src/features/the-feature-s-name-describes-the                     0.44  The feature's name describes the capability …

2 files, 5 violations, 2 uncertain
judgelint: 2 requests, 3,320 input tokens, $0.0001
```

It exits 1 when there are violations, and 2 on a usage, config, or model
error. Config problems are caught before any request is sent.

## Writing specs

A spec is a README, or any file ending in `.judgelint.md`, with `paths:` in
its frontmatter. Each top-level bullet is a rule.

```markdown
---
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts"]
---
# Service conventions

- **Domain failures are values, never exceptions.** A service returns
  `{ ok: false, error }` for anything a caller could plausibly cause.
- **No I/O except through the injected Store.** No timers, no fetch, no console.
```

The model gets the spec and the numbered file. judgelint asks whether the code
breaks each bullet and whether it follows it, and averages the two answers.
A rule's id comes from the start of its bullet, like
`src/services/no-i-o-except-through-the`. Bullets that say "should" or
"prefer" are warnings, and the rest are errors.

If the model misreads a bullet, describe both sides under it:

```markdown
- **No I/O except through the injected Store.** No timers, no fetch, no console.
  violation: calls fetch, console, or a timer directly
  compliant: reads and writes only through the Store it's given
```

They make the model more decisive. A loose description can also flag code
you meant to allow, so check them against examples.

| Frontmatter | What it does |
|---|---|
| `paths`, `excludes` | Globs for the files the spec covers, relative to the project root. |
| `context` | Files the model reads along with each file, like shared types. They're never judged. |
| `scope` | `window`, the default, asks about every 40 lines so findings have line numbers. `file` asks once per file. `directory` asks once per directory and shows the model every file in it. |
| `severity`, `threshold` | Set the severity or threshold for every rule in the spec. |

Each answer is the probability that the code breaks the rule. At 0.7 or above
it's a violation. Between 0.4 and 0.7 it's reported as uncertain, which
doesn't fail the run.

### Rules written as questions

When a convention doesn't fit in a bullet, write it as a question in
`.judgelint/rules/<id>.md`:

```markdown
---
question: Is any file in this directory unreachable from index.ts through its imports?
yes_means: A file nothing in the feature imports, or a directory with no index.ts at all.
no_means: Every file is imported, directly or indirectly, by index.ts.
scope: directory
paths: ["src/features/*"]
---
Every file in a feature is reachable from index.ts.
```

Add `fail_when: no` when a "no" is the violation, as in "Does this service
validate its input first?"

## Explaining exceptions

When code breaks a rule on purpose, explain why in a `judgehint:` comment. Any
comment style works.

```ts
// judgehint: throwing is intentional. Only the nightly job calls this, after
// checking the review, so a bad id here is a programmer error.
```

For each rule, judgelint asks whether a hint in the same 40 lines gives a
reason the code can break it. If it does, the finding is reported as excused
and doesn't fail the run. A hint only excuses the rule it explains, and a hint
with no reason, like "this is intentional", doesn't excuse anything.

## Testing rules

Test each rule against examples. Put files that follow it in
`.judgelint/examples/<rule id>/pass/` and files that break it in `fail/`.
`judgelint test` shows which ones the model gets wrong:

```text
lib/no-silent-rescues  9/10
  ok   pass 0.03  .judgelint/examples/lib/no-silent-rescues/pass/logs_and_reraises.rb
  MISS pass 0.79  .judgelint/examples/lib/no-silent-rescues/pass/retries_then_raises.rb
  ok   fail 0.94  .judgelint/examples/lib/no-silent-rescues/fail/assigns_default.rb
```

When an example fails, reword the bullet or split it into narrower rules. The
model doesn't see the `pass/` or `fail/` part of the path. For a directory
rule, each example is a directory.

## CI

```sh
judgelint --base main            # changes since the merge base with main, plus uncommitted work
judgelint --pr                   # changes in the current pull request
judgelint --pr --format github   # GitHub annotations on the changed lines (json and sarif work too)
```

These only ask about the 40-line windows that changed, so existing code
doesn't block a new pull request. `--pr` gets the base branch from GitHub
Actions, GitLab, Buildkite, Bitbucket, Azure Pipelines,
`JUDGELINT_BASE_BRANCH`, or `gh`. Fetch enough history for git to find the
merge base.

## Configuration

`.judgelint.yml` has four settings:

```yaml
models: [typesafe]       # provider or provider:model; list two to average them
threshold: 0.7
ignore: ["vendor/**"]    # files no rule checks, and READMEs that aren't specs
max_cost_usd: 1.00       # refuse a run estimated to cost more, unless --yes
```

Every run prints what it cost. Answers are cached in `.judgelint/cache.json`,
so a file that hasn't changed costs nothing. Commit the cache to share it.
`judgelint --help` lists the flags.

Two models give steadier answers. On the [demo app](examples/scoop-society),
Jev alone leaves about 10 findings uncertain, and Jev averaged with
Cloudflare's Clef leaves 4, for about $0.02 a run.

### Providers

`judgelint providers` lists them. Tested against the live APIs: `typesafe`
(Jev, the default), `openrouter`, `celeris`, `cloudflare`, and `openai`.
Set up from their docs: `perplexity`, `vercel`, `digitalocean`, `upstage`,
`hanzo`, `foundry`, `databricks`, `ollama`, `llamacpp`, `vllm`, and
`litellm`. Each one reads its key from the provider's usual variable, like
`TYPESAFE_API_KEY`.

For any other System One or Decisions endpoint, add a mapping to `models`:

```yaml
models:
  - api_base: https://gateway.example.com/${TEAM}   # ${VAR} reads the environment
    model: some-decider
    api_key_env: GATEWAY_KEY
    # path: /v1/systemone   protocol: system_one|decisions   auth: bearer|basic|none|header:<name>
    # headers: {}   provider_options: {}   price_per_million: 0.04   batch_size: 32
```

## Building from source

judgelint is written in Ruby and compiled with
[Spinel](https://github.com/matz/spinel).

```sh
bundle install
bundle exec rake test
git clone https://github.com/matz/spinel ../spinel && (cd ../spinel && make deps && make)
SPINEL=../spinel/bin/spinel bundle exec rake spinel        # builds build/judgelint
SPINEL=../spinel/bin/spinel bundle exec rake test:spinel   # runs the tests against the binary
bundle exec rake example                                   # asks Jev about the demo app again
```

## Credits

judgelint was inspired by [praxis](https://github.com/zarpay/praxis-cli), and
it reads praxis specs, including `cohort: by_file` and `by_directory`. The
demo app in [examples/scoop-society](examples/scoop-society) comes from praxis.

## License

MIT. The demo app keeps praxis's MIT license.
