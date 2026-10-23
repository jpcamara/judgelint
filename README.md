# judgelint

Lint for the conventions a linter can't check.

Write your team's conventions as bullets in a README. judgelint asks a System
One decision model, such as TypeSafe's Jev, whether each file breaks each
one, and reports violations with line ranges and exit codes, like a linter.
Answers take a few hundred milliseconds and cost a fraction of a cent.

Inspired by [praxis](https://github.com/zarpay/praxis-cli), which reads the
same kind of specs with chat models. judgelint trades praxis's written
findings for speed and cost, and reads praxis's specs as they are. Ruby with
no dependencies; also a native binary, built with
[Spinel](https://github.com/matz/spinel).

## Quick start

```sh
gem install judgelint
judgelint init                # .judgelint.yml and an example spec
export TYPESAFE_API_KEY=...
judgelint test                # judge the spec's examples
judgelint --base main         # check what changed since main
judgelint                     # or every file the specs govern
```

On [praxis's demo](examples/scoop-society) (long messages cut here):

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

Exit status: 0 clean, 1 violations (or misjudged examples for `judgelint
test`), 2 for usage, configuration, or model errors. Everything that can be
checked is checked before the first paid request.

## Specs

A README, or any `*.judgelint.md`, whose frontmatter has `paths:` is a spec.
Each top-level bullet is a rule.

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

The model is asked each bullet as written: "Do lines 1-40 of the file (the
rest is context) break this convention? Answer yes only when those lines
clearly break it, not when it doesn't apply to them." It sees the whole file,
with numbered lines. Rules are named from their lead words
(`src/services/no-i-o-except-through-the`), and a bullet that says "should"
or "prefer" is a warning, anything else an error.

| Frontmatter | |
|---|---|
| `paths`, `excludes` | Globs for the files the spec governs, from the project root. |
| `context` | Files the model reads alongside, such as shared types, but never judges. |
| `scope` | `window` (default) asks about each 40 lines, so findings name lines; `file` asks once per file; `directory` asks once per directory `paths` matches, with every file in it. Praxis's `cohort: by_file` and `by_directory` work too. |
| `severity`, `threshold` | Override the wording's severity, or the config's threshold, for every rule in the spec. |

A rule's answer is the probability the code breaks it: at or above the
threshold (0.7) it's a violation, within 0.3 below it's uncertain (reported,
never failing).

**When a bullet isn't enough**, write that rule as a question in
`.judgelint/rules/<id>.md`, with criteria the model weighs its answer against:

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

`fail_when: no` inverts a question like "Does this service validate its
input first?".

**Suppress** a finding where a person has decided the code is fine, with a
reason: `# judgelint:disable <rule> -- <reason>` covers the 40 lines it's in,
and `judgelint:disable-file` the whole file. Any comment style works.

## Examples

Decision models classify well and apply policies less well, so the way to
know a rule works is to try it. Put examples under
`.judgelint/examples/<rule id>/pass/` (must not be violations) and `fail/`
(must be), and `judgelint test` reports what the model gets wrong:

```text
lib/no-silent-rescues  9/10
  ok   pass 0.03  .judgelint/examples/lib/no-silent-rescues/pass/logs_and_reraises.rb
  MISS pass 0.79  .judgelint/examples/lib/no-silent-rescues/pass/retries_then_raises.rb
  ok   fail 0.94  .judgelint/examples/lib/no-silent-rescues/fail/assigns_default.rb
```

A miss means the bullet needs rewording or the convention is too broad for
one question. (Saying a retry that eventually raises is fine took this repo's
own rule, in [lib/README.md](lib/README.md), to 10/10.) The model sees each
example's path relative to `pass/` or `fail/`, so the directory never gives
the answer away. For a directory rule, each example is a directory.

## In CI

```sh
judgelint --base main            # since the merge base with main, uncommitted work included
judgelint --pr                   # the pull request's base branch
judgelint --pr --format github   # annotations on the changed lines (also: json, sarif)
```

`--base` asks only about the 40-line windows a change touched, and about
directories with a changed file, so old code can't block new work. `--pr`
reads the base branch from the CI (GitHub Actions, GitLab, Buildkite,
Bitbucket, Azure Pipelines, or `JUDGELINT_BASE_BRANCH`), then `gh`. Check out
enough history for the merge base.

## Configuration

`.judgelint.yml` has four settings:

```yaml
models: [typesafe]       # a model is provider[:model]; list two to average their answers
threshold: 0.7
ignore: ["vendor/**"]    # files no rule judges, and READMEs that are never specs
max_cost_usd: 1.00       # refuse a run estimated over this, unless --yes
```

Flags: `--base`, `--pr`, `--format`, `--model` (replaces `models` for one
run), `--no-cache`, `--yes`, `--config`.

Every run ends with its cost. Answers are cached in `.judgelint/cache.json`
by file, question, and model, so an unchanged file costs nothing; commit the
cache to share it.

**Two models are more certain than one.** On praxis's demo, Jev alone leaves
17 or 18 findings uncertain; averaging Jev and Cloudflare's Clef leaves 5,
with the same 12 of 14 violations found and none false, for about a cent a
run (`models: [typesafe, cloudflare]`). Each model's answers are cached on
their own, and all of a file's requests go out at once.

### Providers

`judgelint providers` lists them. Live-tested: `typesafe` (Jev, the default),
`openrouter`, `celeris`, `cloudflare`, and `openai` (its Decisions API). From
their docs: `perplexity`, `vercel`, `digitalocean`, `upstage`, `hanzo`,
`foundry`, `databricks`, and local `ollama`, `llamacpp`, `vllm`, and
`litellm`. Each reads its key from the usual variable (`TYPESAFE_API_KEY`,
`CLOUDFLARE_API_TOKEN`, and so on).

Any other System One or Decisions endpoint is a mapping in `models`:

```yaml
models:
  - api_base: https://gateway.example.com/${TEAM}   # ${VAR} reads the environment
    model: some-decider
    api_key_env: GATEWAY_KEY
    # path: /v1/systemone   protocol: system_one|decisions   auth: bearer|basic|none|header:<name>
    # headers: {}   provider_options: {}   price_per_million: 0.04   batch_size: 32
```

## Native binary

```sh
git clone https://github.com/matz/spinel && (cd spinel && make deps && make)
SPINEL=../spinel/bin/spinel rake spinel        # build/judgelint
SPINEL=../spinel/bin/spinel rake test:spinel   # the tests, against it too
```

On macOS and Linux, `gem install` picks a platform gem with the binary
inside, statically linked, and `judgelint` runs it; elsewhere, Windows
included, the gem runs as plain Ruby. Run directly, the binary starts in 4 ms
against CRuby's 110, and in a 300-file benchmark it was 1.4x faster than
CRuby on one thread and 2x on eight. The code stays inside what Spinel
compiles: plain classes instead of `Data.define`, a hand-written option
parser, no gems.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rake example      # re-ask Jev about praxis's demo and check it
```

## License

MIT
