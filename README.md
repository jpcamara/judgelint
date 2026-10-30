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
for macOS and Linux, on arm64 and x86_64. Linux needs glibc 2.34 or newer
(Ubuntu 22.04, Debian 12, RHEL 9). `gem install judgelint` installs the same
binary. On another Unix, or an older glibc, build it with Rust:
`cargo install --git https://github.com/jpcamara/judgelint`. It doesn't build
on Windows.

Each release's archives and gems carry a build attestation from the GitHub
Actions run that built them, from the tagged source. To check one:
`gh attestation verify judgelint-aarch64-apple-darwin.tar.gz --repo jpcamara/judgelint`.

## Getting started

Write your conventions as bullets in a `CONVENTIONS.md`:

```markdown
- **No silent rescues.** A rescue logs the error, re-raises it, or returns a
  failure the caller sees.
- **Error messages say what to do next.** A raised error names what was wrong
  and what would work instead.
```

Then set your TypeSafe API key and run it:

```sh
export TYPESAFE_API_KEY=...
judgelint                 # checks every file
judgelint --base main     # checks only what changed since main
```

```text
lib/profile.rb
  x error      root/no-silent-rescues              5       0.99  No silent rescues.
  x error      root/error-messages-say-what-to-do  9       0.97  Error messages say what to do next.

1 file, 2 violations
judgelint: 1 request, 940 input tokens, $0.0000, typesafe:jev-latest
```

That's all the setup there is. A `CONVENTIONS.md` covers the files in its
directory and below, except Markdown, lockfiles, and names that start with a
dot. A pattern in `paths:` matches a dotted name only when it names the dot,
like `.github/*.yml`. In a git repository,
judgelint skips what git ignores. It also skips binary files.

judgelint asks Jev on TypeSafe. To use another provider, set `models` in
`.judgelint.yml` (see [Configuration](#configuration)).

Here's a run on the [demo app](examples/scoop-society), with the messages shortened:

```text
$ judgelint src/services/apply-refund.ts src/features/flavor-of-day
src/services/apply-refund.ts
  ? uncertain  src/services/a-service-module-exports-exactly-one         1-21            0.47  A service module exports exactly one entry point.
  x error      src/services/domain-failures-are-values-never-exceptions  13              1.00  Domain failures are values, never exceptions.
  x error      src/services/error-messages-are-written-for-the           13              1.00  Error messages are written for the API consumer.
  ? uncertain  src/services/input-is-validated-before-any-work           10              0.51  Input is validated before any work happens.
  x error      src/services/every-service-has-a-doc-comment              1-21            1.00  Every service has a doc comment …
src/features/flavor-of-day
  x error      src/features/exactly-one-entry-point-index-ts             old-rotation.ts 1.00  Exactly one entry point, `index.ts`, …
  ? uncertain  src/features/types-live-in-a-dedicated-feature            flavor.ts       0.53  Types live in a dedicated `<feature>-types.ts` file.
  x error      src/features/logic-files-are-verb-first-kebab             flavor.ts       0.99  Logic files are verb-first kebab-case …
  x error      src/features/no-orphaned-files                            old-rotation.ts 0.79  No orphaned files.

2 files, 6 violations, 3 uncertain
judgelint: 2 requests, 6,437 input tokens, $0.0003, typesafe:jev-latest
```

A finding names the line that breaks the rule, or the file in a directory,
when the model is sure of one. Otherwise it shows the lines it was asked
about.

It exits 1 when there are violations, and 2 on a usage, config, or model
error. Config problems are caught before any request is sent.

In a terminal, the report is in color. Set `NO_COLOR` to turn color off, or
`FORCE_COLOR` to keep it when the output is piped.

## Writing specs

A spec is a `CONVENTIONS.md`, a file ending in `.judgelint.md`, or a README
with `paths:` in its frontmatter. Each top-level bullet is a rule. Put a spec
in a subdirectory for conventions that apply only there, or use `paths:` to
choose the files:

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

The model gets the spec and the numbered file. For each bullet, it chooses
whether the code breaks it, follows it, or isn't covered by it, and which line
breaks it most clearly. A rule's id comes from the spec's directory and the start of its bullet, like
`src/services/no-i-o-except-through-the`. Bullets that say "should" or
"prefer" are warnings, and the rest are errors.

If the model misreads a bullet, describe breaking and following it:

```markdown
- **No I/O except through the injected Store.** No timers, no fetch, no console.
  violation: calls fetch, console, or a timer directly
  compliant: reads and writes only through the Store it's given
```

They make the model more decisive. A loose description can also flag code
you meant to allow, so check them against examples.

### Examples

Show the model what breaking and following a rule looks like. Under a bullet,
put code blocks after a `Bad:` or `Good:` line:

````markdown
- **Jobs take ids, not records.** Arguments to `perform_later` are ids and
  plain values. A record can change or disappear before the job runs.

  Bad:

  ```ruby
  WelcomeEmailJob.perform_later(user)
  ```

  Good:

  ```ruby
  WelcomeEmailJob.perform_later(user.id, locale: user.locale)
  ```
````

The model reads them with the rest of the spec, and `judgelint test` checks
that it gets each one right. [examples/conventions](examples/conventions) has
complete specs for Ruby, TypeScript, Python, and Postgres migrations, with
code to run them on.

| Frontmatter | What it does |
|---|---|
| `paths`, `excludes` | Globs for the files the spec covers, relative to the project root. A README needs `paths`. |
| `context` | Files the model reads along with each file, like shared types. They're never judged. |
| `scope` | `window`, the default, asks about every 40 lines so findings have line numbers. `file` asks once per file. `directory` asks once per directory, shows the model every file in it, and names the file that breaks the rule. |
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

`judgelint test` judges each rule's examples and shows which ones the model
gets wrong:

```text
root/jobs-take-ids-not-records  2/2
  ok   fail 1.00  CONVENTIONS.md:67
  ok   pass 0.00  CONVENTIONS.md:73
root/no-silent-rescues  2/3
  ok   pass 0.03  .judgelint/examples/root/no-silent-rescues/pass/logs_and_reraises.rb
  MISS pass 0.79  .judgelint/examples/root/no-silent-rescues/pass/retries_then_raises.rb
  ok   fail 0.94  .judgelint/examples/root/no-silent-rescues/fail/assigns_default.rb
```

`Bad:` and `Good:` blocks in the spec are the quickest examples to write. The
model also reads them during every check, so passing them shows it
understands the rule, not that it gets the rule right on code it hasn't seen.
For that, and for longer examples, put whole files that follow the rule in
`.judgelint/examples/<rule id>/pass/` and files that break it in `fail/`. The
model doesn't see the `pass/` or `fail/` part of the path. For a directory
rule, each example is a directory.

When an example fails, reword the bullet or split it into narrower rules.
`judgelint init` writes a spec with examples to start from.

## CI

```sh
judgelint --base main            # changes since the merge base with main, plus uncommitted work
judgelint --pr                   # changes in the current pull request
judgelint --pr --format github   # GitHub annotations on the changed lines (json and sarif work too)
```

These ask only about the lines that changed, with the rest of the file as
context, so existing code doesn't block a new pull request. When the model
says the clearest violation is on a line the change didn't touch, it
doesn't count, even if a changed line breaks the same rule less clearly.
A new file is
all changed lines. Rules about a whole file (`scope: file`) still read the
whole file when any of it changed, and a directory rule asks about a
directory when a file in it was changed, added or deleted. Only `check`
takes `--base` and `--pr`. `--pr` checks against `JUDGELINT_BASE_BRANCH`
when it's set, or else the base branch that GitHub Actions, GitLab,
Buildkite, Bitbucket, Azure Pipelines or `gh` names. git needs the history
back to the merge base, except on GitHub Actions' own checkout (below).

Under `--base` or `--pr`, a changed file judgelint can't judge fails the
run: one too large for the model, one the model refused to answer about,
even in part, one that leads outside the project, or a binary one. Images,
fonts, archives and other formats that are never code are left out instead.

On GitHub Actions, the default checkout is enough. Keep the cache between
pushes:

```yaml
- uses: actions/checkout@v4
- uses: actions/cache@v4
  with:
    path: .judgelint/cache.bin
    key: judgelint-${{ github.run_id }}
    restore-keys: judgelint-
- run: judgelint --pr --format github
```

That checkout is the merge commit GitHub makes for the pull request, and
`--pr` compares it with its first parent: the base branch, or for a stacked
pull request, the merge commit of the one below it. So a stacked pull
request is checked for its own changes, with the config of what it lands
on. judgelint fetches that parent with the checkout's credentials, so leave
`persist-credentials` at its default. Line numbers are the merge commit's:
if the base branch changed lines above an edit, an annotation can sit a few
lines from where the "Files changed" tab shows it.

To check the pull request's own commit instead, check it out with
`ref: ${{ github.event.pull_request.head.sha }}` and fetch the history
with `fetch-depth: 0` (`filter: blob:none` skips old file contents). `--pr`
then compares with the branch the pull request targets, read from GitHub's
event, since `GITHUB_BASE_REF` names the branch a whole stack targets.

### Pull requests from people you don't trust

`--pr` reads `.judgelint.yml` from the base branch, or for a stacked pull
request from the one below it, not from the pull request, so a pull request can't change where its code is sent or which
API key goes with it.

The pull request's own specs and cache are used, so a new or changed
convention applies to it right away. That also means a pull request can
change its rules or the answers in its cache. Review those like any other
change, and have GitHub hold workflow runs on pull requests from forks
until you approve them (Settings → Actions).

`--pr` judges what the pull request committed. Anything else in the
checkout, like a file an earlier CI step wrote, is never sent, whatever the
pull request's `.gitignore` says.

Run judgelint with `--pr` on pull requests; a plain `judgelint` or `--base`
run uses the checked-out files as they are.

`--pr` trusts the branch a pull request targets, so only check pull requests
against branches that only trusted people push to.

Even so, give the job only the model's API key. The pull request's code is
still what's being read, and the model can be argued with: a comment in the
code can sway its answer. judgelint is a reviewer, not a security gate.

## What gets sent

For each file a rule checks, the model gets the file's path and its whole
contents, numbered, with the spec's text and any `context:` files the rule
names. A directory rule sends every file in the directory. Nothing else on
your machine is read or sent:

- Only files inside the directory judgelint runs in, and none reached
  through a link that leads out of it.
- In a git repository, only files git tracks or would add, never ignored
  ones. Under `--pr`, only files git tracks.
- No binary files, and nothing over 4 MB, or 4 MB for a directory's files
  together.

Requests go to the model's API over https, or plain http to a server on
your own machine. The API key goes only to its own provider's address: a
provider pointed somewhere else with `api_base` needs its own `api_key_env`.

## Configuration

judgelint runs without a config file. `.judgelint.yml` has four settings:

```yaml
models: [typesafe]       # provider or provider:model; list two to average them
threshold: 0.7
ignore: ["vendor/**"]    # files no rule checks, and READMEs that aren't specs
max_cost_usd: 1.00       # refuse a run estimated to cost more, unless --yes
```

A model judgelint has no price for, like any model on OpenRouter, needs a
`price_per_million` (see below) before a run will spend money on it, or
`--yes`. A server on your own machine costs nothing.

Every run prints what it cost. Answers are cached in `.judgelint/cache.bin`,
so a file that hasn't changed costs nothing. Commit the cache to share it.
Runs at the same time can share it too.
`judgelint --help` lists the flags.

List two models to average their answers, like `models: [typesafe,
cloudflare]`. Each model's answers are cached separately.

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
    api_key_env: GATEWAY_KEY                         # sent only to this api_base
    # path: /v1/systemone   protocol: system_one|decisions   auth: bearer|basic|none|header:<name>
    # headers: {}   provider_options: {}   price_per_million: 0.04   batch_size: 32
```

## Building from source

judgelint is written in Rust. The end-to-end tests are in Ruby.

```sh
cargo build --release       # builds target/release/judgelint
bundle install
bundle exec rake test       # runs the Rust tests, then the end-to-end tests against the binary
bundle exec rake example    # asks Jev about the demo app again
```

## Credits

judgelint was inspired by [praxis](https://github.com/zarpay/praxis-cli), and
it reads praxis specs, including `cohort: by_file` and `by_directory`. The
demo app in [examples/scoop-society](examples/scoop-society) comes from praxis.

## License

MIT. The demo app keeps praxis's MIT license.
