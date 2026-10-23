# judgelint

Lint for the conventions a linter can't check.

Every codebase has rules only a reader can judge: a rescue that quietly drops
an error, an error message that doesn't tell the caller what to fix, a service
that does work before validating its input. judgelint turns each one into a
yes/no question and asks a System One decision model, such as TypeSafe's Jev,
whether a file breaks it. Answers come back as probabilities in a few hundred
milliseconds, so judgelint can run like a linter: on every file, in CI, with
exit codes.

It was inspired by [praxis](https://github.com/zarpay/praxis-cli), which holds
files to written specs using chat-model reviewers. judgelint makes a different
trade: narrow questions to a fast decision model instead of open-ended review.
That means no free-text findings and no line numbers, but answers are cheap,
fast, and calibrated enough to threshold.

judgelint is Ruby with no runtime dependencies, and compiles to a native
binary with [Spinel](https://github.com/matz/spinel). It isn't tied to Ruby
code: [examples/scoop-society](examples/scoop-society) runs it on praxis's own
TypeScript demo and finds the same violations praxis's chat-model reviewer does.

## Install

```sh
gem install judgelint
```

On macOS (arm64, x86_64) and Linux (x86_64, aarch64), RubyGems picks a
platform gem with the native binary inside, and `judgelint` runs it. Elsewhere,
Windows included, you get the same tool in plain Ruby.

## Quick start

```sh
judgelint init                  # writes .judgelint.yml and an example spec
export TYPESAFE_API_KEY=...
judgelint test                  # judge the example rule's examples
judgelint --base main           # check what changed since main
judgelint app/services          # or these paths
judgelint                       # or every file the rules govern
```

```text
$ judgelint src/services/apply-refund.ts src/services/parlor.ts src/features/flavor-of-day
src/services/apply-refund.ts
  x error      src/services/domain-failures-are-values-never-exceptions  1-21    0.95  Domain failures are values, never exceptions.
  x error      src/services/error-messages-are-written-for-the           1-21    0.93  Error messages are written for the API consumer.
  x error      src/services/every-service-has-a-doc-comment              1-21    0.97  Every service has a doc comment stating its purpose in one sentence and enumerating its domain failure modes, so a caller can handle every `error` without reading the body.
src/services/parlor.ts
  x error      src/services/a-service-module-exports-exactly-one         1-40    0.89  A service module exports exactly one entry point.
  x error      src/services/the-module-name-is-verb-first                1-40    0.85  The module name is verb-first kebab-case and says what the service does.
  ? uncertain  src/services/input-is-validated-before-any-work           1-40    0.54  Input is validated before any work happens.
  ? uncertain  src/services/services-do-one-thing                        41-47   0.46  Services do one thing.
  ? uncertain  src/services/every-service-has-a-doc-comment              41-47   0.46  Every service has a doc comment stating its purpose in one sentence and enumerating its domain failure modes, so a caller can handle every `error` without reading the body.
src/features/flavor-of-day
  x error      src/features/exactly-one-entry-point-index-ts                     0.79  Exactly one entry point, `index.ts`, which re-exports the feature's entire public API.
  x error      src/features/logic-files-are-verb-first-kebab                     0.87  Logic files are verb-first kebab-case (`build-menu.ts`, `pick-winners.ts`) and follow the service conventions (`src/services/README.md`).
  ? uncertain  src/features/no-orphaned-files                                    0.57  No orphaned files.
  ? uncertain  src/features/the-feature-s-name-describes-the                     0.45  The feature's name describes the capability (`tasting-menu`), not its implementation.

3 files, 7 violations, 5 uncertain
judgelint: 0 requests, 0 input tokens, $0.0000
```

That's [praxis's demo](examples/scoop-society), checked against its own README
specs from the answer cache. Each finding names the lines it came from. Exit status is 0 when clean, 1 when
an `error` rule is violated (or, for `judgelint test`, when an example is
misjudged), and 2 for usage, configuration, or model errors. Everything that
can be checked (rules, examples, budgets, keys, git refs) is checked before
the first paid request.

## Rules

Write conventions the way you already do: as bullets in a README next to the
code they govern. A README (or any `*.judgelint.md`) whose frontmatter has
`paths:` is a spec, and each top-level bullet is a rule.

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

That's two rules, `src/services/domain-failures-are-values-never-exceptions`
and `src/services/no-i-o-except-through-the`, named from their lead words. The
model is asked each bullet as written: "Do lines 1-40 of the file (the rest is
context) break this convention? Answer yes only when those lines clearly break
it, not when it doesn't apply to them." A bullet that says "should" or
"prefer" is a warning; anything else is an error. judgelint reads praxis specs
as they are, `cohort` included (see [examples/scoop-society](examples/scoop-society)).

| Frontmatter | Default | Meaning |
|---|---|---|
| `paths`, `excludes` | required, none | Globs for the files the spec governs, from the project root. `**/` matches zero or more directories. |
| `context` | none | Files the model reads alongside, such as shared types. They're never judged. |
| `scope` (or praxis's `cohort`) | `window` | `window` asks about each range of lines, so findings name lines; `file` (`by_file`) asks once about each file; `directory` (`by_directory`) asks once about each directory `paths` matches, with every file in it. |
| `severity` | from the wording | `error` fails the run; `warning` is reported only. |
| `threshold` | config's | Violation probability at or above which the code is a violation. |

The model sees the whole file with numbered lines, and every rule that governs
it shares one request (or a few, packed to the provider's limits), so a file's
verdicts never depend on which files ran beside it. A rule's verdict is its
worst window. The answer is the probability the code breaks the convention: at
or above `threshold` it's a violation, at or above `warn_at` it's uncertain
(reported, never fails), and below that it passes.

### Precise rules

A bullet is usually enough. When one isn't (the [example](examples/scoop-society)
shows a bullet that needs more reasoning than a decision model does), write
that rule as a question in `.judgelint/rules/<id>.md`, with criteria the model
weighs its answer against:

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

`question`, `yes_means`, and `no_means` are what the model sees. `fail_when:
no` inverts a question like "Does this service validate its input first?", and
`message` and `id` default to the body's first paragraph and the file name. A
file in `.judgelint/rules/` without a `question` is a spec like any README.

### Writing rules the model can apply

- **Name the replacement, not just the ban.** A rule that says what to do
  instead gives the model something to compare the code against.
- **Name exceptions concretely.** "Some cases are fine" is too vague to apply;
  describe the exception the way the code would show it.
- **Put the hard cases in `yes_means` and `no_means`.** That's where the model
  decides borderline code. This repo's rule says a retry that eventually
  raises counts as no.
- **Fix precision with wording and examples, not the threshold.** A higher
  threshold drops real violations along with the false ones.
- **Check changes, not the whole repo.** A broad rule flags more old code that
  is fine by design than new code that isn't. A full run is for finding the
  exceptions and examples a rule is missing.
- **Exclude test-only and generated code explicitly** in every rule whose
  globs cover it.

### Suppressions

When a person has decided flagged code is fine, say so where it is, with a
reason:

```ruby
# judgelint:disable lib/no-silent-rescues -- the caller retries and re-raises
# judgelint:disable-file lib/no-silent-rescues, ruby/error-messages-say-what-to-do -- generated code
```

A `disable` comment covers the window it falls in; `disable-file` covers the
whole file. The comment can start with `#`, `//`, `--`, `/*`, `<!--`, or `;`.
A suppression without a reason, or naming a rule that doesn't exist, stops the
run before anything is sent. Suppressed rules aren't asked about, and are
counted in the summary.

### Examples

Decision models are good at classifying and much weaker at applying a policy:
on StreamDecisionBench's rule-following tasks they score 22–62%, where chat
models with light reasoning score over 90%. Narrow questions help a lot, but
the only way to know whether a rule works is to try it. So rules carry
examples:

```text
.judgelint/examples/<rule id>/pass/...   # must not be judged violations
.judgelint/examples/<rule id>/fail/...   # must be
```

For a precise rule they sit beside it, in `.judgelint/rules/<id>/pass/` and
`fail/`; for a directory rule, each example is a directory under `pass/` or
`fail/`.

`judgelint test` judges every example and reports which ones the model gets
wrong, with the probability it gave. A rule with examples needs at least one
of each kind, or `test` stops before sending anything; rules with none are
listed, so you can see what's untested:

```text
lib/no-silent-rescues  9/10
  ok   pass 0.15  .judgelint/examples/lib/no-silent-rescues/pass/logs_and_defaults.rb
  ok   pass 0.03  .judgelint/examples/lib/no-silent-rescues/pass/logs_and_reraises.rb
  MISS pass 0.79  .judgelint/examples/lib/no-silent-rescues/pass/retries_then_raises.rb
  ok   fail 0.94  .judgelint/examples/lib/no-silent-rescues/fail/assigns_default.rb
  ...
```

A miss means the question needs rewording, the threshold needs moving, or the
convention is too broad for one question. (Adding "retries before eventually
raising" to the rule took this repo's own rule, in [lib/README.md](lib/README.md), to 10/10.) The model sees
each example's path relative to `pass/` or `fail/`, so the directory never
leaks the answer.

When you add an exception to a rule, add a `pass/` example that scored near
the threshold before the change: watching its score drop shows the new clause
does something. Run `judgelint test` on every rule edit; this repo's ten
examples cost $0.0002 on Jev.

## Checking a change

```sh
judgelint --base main        # since the merge base with main, uncommitted work included
judgelint --pr               # the pull request's base branch
```

`--base` asks only about windows that contain a changed line, so old code
can't block new work. Changed lines come from `git diff -U0` against the merge
base; a pure deletion marks the line above the gap, untracked files count as
new, and deleted files are skipped. `--pr` finds the base branch from
`JUDGELINT_BASE_BRANCH`, then the CI's own variable (GitHub Actions, GitLab,
Buildkite, Bitbucket, or Azure Pipelines), then `gh pr view`, and fetches it
from `origin`. In CI, check out enough history for the merge
base (`fetch-depth: 0` on GitHub Actions).

Output for CI: `--format github` prints Actions annotations on the changed
lines, `--format sarif` writes SARIF for code scanning, and `--format json`
includes each finding's `lines` and the run's `usage`.

```yaml
# .github/workflows/judgelint.yml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- run: gem install judgelint && judgelint --pr --format github
  env: { TYPESAFE_API_KEY: "${{ secrets.TYPESAFE_API_KEY }}" }
```

## Cost

Decision models bill input tokens only, so the file you send is the cost.
Every run ends with a line like `judgelint: 16 requests, 31,518 input tokens,
$0.0013` on stderr, failed runs included, since requests that succeeded before
the failure are billed. Before sending anything, judgelint plans every request
and estimates its tokens (three bytes a token), and:

- skips a file whose state plus widest question is over `max_state_tokens`,
  and reports it as skipped;
- packs a file's questions into as few requests as fit `max_request_tokens`
  and the provider's `batch_size`;
- refuses a run estimated over `max_cost_usd`, and a full run over
  `full_run_limit` files, unless you pass `--yes`.

Prices are per provider preset (`judgelint providers`); OpenRouter reports
each request's cost, and for another model set `price_per_million`. For
scale, a full run over this repo's 20 files is 20 requests and about 34,000
input tokens: $0.0014 on Jev.

## Configuration

`.judgelint.yml`:

```yaml
provider: typesafe        # see `judgelint providers`
model: jev-latest         # defaults to the provider's
threshold: 0.7            # violation probability that counts as a violation
warn_at: 0.4              # at least this, but below threshold, is reported as uncertain
rules: .judgelint/rules   # precise rules and specs, besides READMEs
ignore: ["vendor/**"]     # files no rule judges, and READMEs that are never specs
window_lines: 40          # lines per window
repeat: 1                 # send each request this many times and average (Jev varies run to run)
threads: 8                # files judged at once
cache: .judgelint/cache.json   # or false
max_state_tokens: 30000   # a file plus its widest question; larger files are skipped
max_request_tokens: 60000 # questions are packed into requests under this
max_cost_usd: 1.00        # refuse a run estimated over this, unless --yes
full_run_limit: 300       # most files to check with no paths or --base, unless --yes
# price_per_million: 0.042  # USD per million input tokens, for a model without a preset price
timeout: 30
retries: 3                # for connection errors, 408, 429, 5xx, and 529, honoring Retry-After
```

Command-line flags override the file: `--base`, `--pr`, `--provider`,
`--model`, `--threshold`, `--no-cache`, `--yes`, `--config`, and `--format`
(text, json, github, sarif). Choosing a different provider on the command line
drops the file's provider settings (model, api_base, and so on), so
`judgelint test --provider openai` asks OpenAI for its own default model.

### Providers

Decision models are served in two shapes. Most providers take TypeSafe's
System One request (`{model, state, questions}` keyed by name, yes/no as
`noul`). OpenAI's Decisions API takes `{model, input, questions: [...]}` with
yes/no as `predicate`. judgelint speaks both, and the presets below set the
URL, protocol, and auth for each provider. `judgelint providers` lists them.

| `provider` | Default model | Key | Tested |
|---|---|---|---|
| `typesafe` | `jev-latest` (`jev-preview` for Jev 1.14) | `TYPESAFE_API_KEY` | live, 10/10 |
| `openrouter` | `typesafe/jev-1.13` (also `jaredpalmer/kev-4b`, and other decision models) | `OPENROUTER_API_KEY` | live, 10/10 (Kev 9/10) |
| `celeris` | `celeris-1-decision` (also `celeris-1.1-decision`) | `CELERIS_API_KEY` | live, 10/10 both |
| `cloudflare` | `clef` (also `clef-flash`, `clef-omni`) | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | live, 10/10 (omni 9/10) |
| `openai` | `gpt-6-luna` (Decisions API) | `OPENAI_API_KEY` | live, 10/10 |
| `perplexity` | `pplx-decider-latest` | `PERPLEXITY_API_KEY` | from docs |
| `vercel` | `typesafe-ai/jev` (AI Gateway) | `AI_GATEWAY_API_KEY` | from docs |
| `digitalocean` | `typesafe-jev-1.13.0` | `MODEL_ACCESS_KEY` | from docs |
| `upstage` | `solar-decide` (beta) | `UPSTAGE_API_KEY` | from docs |
| `hanzo` | `kai` | `HANZO_API_KEY` | from docs |
| `foundry` | your deployment name; set `api_base` to your resource | `AZURE_API_KEY` | from docs |
| `databricks` | a Unity Catalog name; set `api_base` to your workspace | `DATABRICKS_TOKEN` | from docs |
| `ollama` | a model you've pulled | none (set `api_key_env` for ollama.com) | from docs |
| `llamacpp` | none needed | none | from docs |
| `vllm` | the served model | none | from docs |
| `litellm` | a model your proxy routes | `LITELLM_API_KEY` | from docs |

"Live" means `judgelint test` on this repo's own rule, run through the native
binary on Oct 23, 2026; misses are the model's judgment, not the protocol.
"From docs" means the preset follows the provider's published API, and the
request shape is covered by tests, but it hasn't been run against the real
service.

Any other System One server works by setting the pieces yourself:

```yaml
provider: my-gateway
api_base: https://gateway.example.com/${TEAM}       # ${VAR} reads the environment
path: /v1/systemone        # {model} is replaced by the model id
protocol: system_one       # or decisions
auth: bearer               # basic (user "token"), none, or header:<name>
api_key_env: GATEWAY_KEY
model: some-decider
batch_size: 64             # most questions the server takes per request
headers:                   # sent with every request
  TypeSafe-Danger-Zone-Long-Context: "true"
provider_options:          # merged into the request body
  x_celeris: { explain: true }
```

What judgelint handles for you:

- The path doesn't decide the protocol. Perplexity and Hanzo take System One
  bodies at `/v1/decisions`, and presets set `protocol` and `path` separately.
- Cloudflare wraps answers in `{result: {...}}`; judgelint unwraps it.
- A question the model refuses (OpenAI's `refusal` answer) is reported as
  refused, not as a pass and not as a crash, and isn't cached.
- Error messages are read from whichever shape the provider uses: TypeSafe's
  `detail`, OpenAI's and OpenRouter's `error`, Cloudflare's `errors`, or `message`.
- A preset that needs something from you says so (`Provider foundry needs
  api_base (your Foundry resource endpoint)`), and a missing key is reported
  before any request is sent.

judgelint asks only yes/no questions, so the choice-option and score-level
limits that differ between models don't apply. Context limits do: Kev 4B on
OpenRouter takes 8,192 tokens, so lower `max_bytes` when you use it.

### Cache

Each answer is cached under a hash of the state the model saw (the path and
numbered file), the question, and the model. Editing the file, rewording the
rule, or switching models is a miss; changing a threshold or severity is not,
because the model never saw them. Commit the cache to share answers across
machines and CI.

## Native binary

judgelint is written in the subset of Ruby that Spinel compiles. The same
source runs on CRuby and as a native binary:

```sh
git clone https://github.com/matz/spinel && (cd spinel && make deps && make)
SPINEL=../spinel/bin/spinel rake spinel        # writes build/judgelint
SPINEL=../spinel/bin/spinel rake test:spinel   # runs the CLI tests against it too
SPINEL=../spinel/bin/spinel rake gem:native    # this platform's gem, into pkg/
```

The binary links OpenSSL statically and needs nothing beyond the system's C
library. It reads certificates from `SSL_CERT_FILE`, or else the system bundle
(`/etc/ssl/cert.pem`, `/etc/ssl/certs/ca-certificates.crt`, or
`/etc/pki/tls/certs/ca-bundle.crt`). The [Native gems](.github/workflows/native.yml)
workflow builds and tests the four platform gems. There's no native Windows
build: Spinel's Windows port is best-effort, and the Ruby gem already runs there.

How much the binary saves, with the model taken out (an Apple M2; CRuby 3.4.5;
the 300-file run asks a local stub server, so only judgelint's own work counts):

| | Native binary | Through the platform gem | CRuby | CRuby + YJIT |
|---|---|---|---|---|
| `--version` | 3.7 ms | 46 ms | 108 ms | 134 ms |
| Fully cached run of the example (20 units) | 9.9 ms | 51 ms | 121 ms | 165 ms |
| 300 files x 400 lines, 300 requests, 1 thread | 264 ms | | 366 ms | 421 ms |
| The same, 8 threads | 165 ms | | 327 ms | 386 ms |

Most of CRuby's time on a small run is loading Ruby and the standard library.
On a big run the per-request work is about even, and the binary pulls ahead on
threads, which run in parallel there and take turns under CRuby's GVL. The
platform gem's `judgelint` starts Ruby and hands off to the binary, which costs
about 40 ms; run `libexec/judgelint` from the gem directly to skip it.

Spinel's limits explain the odd choices: plain classes instead of `Data.define`
(Spinel can't compile Data or Struct alongside `net/https` and `json`), a
hand-rolled option parser (it can't compile this use of OptionParser), no
`Hash#fetch` with a Float default on YAML data (miscompiled), and no gems.

## Development

```sh
bundle install
bundle exec rake test
```

## License

MIT
