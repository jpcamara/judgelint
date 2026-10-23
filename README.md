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
judgelint init                  # writes .judgelint.yml and an example rule
export TYPESAFE_API_KEY=...
judgelint test                  # judge the example rule's examples
judgelint --base main           # check what changed since main
judgelint app/services          # or these paths
judgelint                       # or every file the rules govern
```

```text
judgelint: 16 requests, 31,518 input tokens, $0.0013
lib/judgelint/client.rb
  ? uncertain  no-silent-rescue         41-80     0.44  Swallowed exceptions hide bugs until they cost us data.
lib/judgelint/pool.rb
  ? uncertain  no-silent-rescue         1-40      0.56  Swallowed exceptions hide bugs until they cost us data.

16 files, 0 violations, 2 uncertain
```

Each finding names the lines it came from. Exit status is 0 when clean, 1 when
an `error` rule is violated (or, for `judgelint test`, when an example is
misjudged), and 2 for usage, configuration, or model errors. Everything that
can be checked (rules, examples, budgets, keys, git refs) is checked before
the first paid request.

## Rules

A rule is a markdown file in `.judgelint/rules/`. The frontmatter is the
question; the body is the rationale people read.

```markdown
---
question: Does this code rescue an exception and then carry on as if nothing happened?
yes_means: A rescue neither logs the error, re-raises it, nor returns an explicit failure to the caller.
no_means: Every rescue logs, re-raises, or turns the error into a result the caller sees. Code with no rescue counts as no.
paths: ["app/**/*.rb", "lib/**/*.rb"]
excludes: ["lib/tasks/**"]
---
Swallowed exceptions hide bugs until they cost us data.
```

| Key | Default | Meaning |
|---|---|---|
| `question` | required | The yes/no question. Keep it narrow: one convention, answerable from the file alone. |
| `yes_means`, `no_means` | none | What each answer means. Sent to the model as criteria. |
| `fail_when` | `yes` | Which answer is a violation. Use `no` for questions like "Does this service validate its input first?" |
| `scope` | `window` (`file` when `fail_when: no`) | `window` asks about each range of lines; `file` asks once about the whole file; `directory` asks once about each directory `paths` matches, with all its files. |
| `context` | none | Globs for files the model reads alongside, such as shared types. They're never judged. |
| `paths`, `excludes` | `**/*`, none | Globs for the files the rule governs. `**/` matches zero or more directories. |
| `severity` | `error` | `error` fails the run; `warning` is reported only. |
| `threshold` | config's | Violation probability at or above which the file is a violation. |
| `message` | body's first paragraph | What judgelint prints for a violation. |
| `id` | file name | Rule id. |

The model sees the whole file, with numbered lines, and one question per rule
and window: "Look at lines 41-80 of the file; the rest is context. Does this
code ...? Answer yes only when those lines do it, not when the question doesn't
apply." That last sentence keeps the model from flagging code a rule doesn't
cover. All of a file's questions share one request (or a few, packed to the
provider's limits), so a file's verdicts never depend on which files ran
beside it, and a rule's verdict is its worst window.

Some conventions are about how files relate: one entry point per feature, no
orphaned files. A `scope: directory` rule judges each directory its `paths`
match as one unit, with every file in it (and its `context`):

```markdown
---
question: Is any file in this directory unreachable from index.ts through its imports?
scope: directory
paths: ["src/features/*"]
context: ["src/domain/types.ts"]
---
Every file in a feature is reachable from index.ts.
```

A directory rule's examples are directories: `rules/<id>/pass/<name>/` and
`rules/<id>/fail/<name>/`. With `--base`, a directory is checked when a change
touched any file in it.

The answer is the probability of yes, turned into a violation probability by
`fail_when`: at or above `threshold` it's a violation, at or above `warn_at`
it's uncertain (reported, never fails), and below that it passes.

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
# judgelint:disable no-silent-rescue -- the caller retries and re-raises
# judgelint:disable-file no-silent-rescue, other-rule -- generated code
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
.judgelint/rules/no-silent-rescue.md
.judgelint/rules/no-silent-rescue/pass/logs_and_reraises.rb
.judgelint/rules/no-silent-rescue/fail/returns_nil.rb
```

`judgelint test` judges every example and reports which ones the model gets
wrong, with the probability it gave. Every rule needs at least one `pass/`
and one `fail/` example, or `test` stops before sending anything:

```text
no-silent-rescue  9/10
  ok   pass 0.15  .judgelint/rules/no-silent-rescue/pass/logs_and_defaults.rb
  ok   pass 0.03  .judgelint/rules/no-silent-rescue/pass/logs_and_reraises.rb
  MISS pass 0.79  .judgelint/rules/no-silent-rescue/pass/retries_then_raises.rb
  ok   fail 0.94  .judgelint/rules/no-silent-rescue/fail/assigns_default.rb
  ...
```

A miss means the question needs rewording, the threshold needs moving, or the
convention is too broad for one question. (Adding "retries before eventually
raising" to `no_means` took this repo's own rule to 10/10.) The model sees
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
rules: .judgelint/rules
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
