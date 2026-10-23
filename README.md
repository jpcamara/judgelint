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
binary with [Spinel](https://github.com/matz/spinel).

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
judgelint                       # check every file the rules govern
judgelint app/services          # or just these paths
```

```text
lib/judgelint/cache.rb
  x error     no-silent-rescue         0.92  Swallowed exceptions hide bugs until they cost us data.
lib/judgelint/scaffold.rb
  ? uncertain no-silent-rescue         0.51  Swallowed exceptions hide bugs until they cost us data.

17 files, 1 violations, 1 uncertain
```

Exit status is 0 when clean, 1 when an `error` rule is violated (or, for
`judgelint test`, when an example is misjudged), and 2 for usage,
configuration, or model errors.

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
| `paths`, `excludes` | `**/*`, none | Globs for the files the rule governs. `**/` matches zero or more directories. |
| `severity` | `error` | `error` fails the run; `warning` is reported only. |
| `threshold` | config's | Violation probability at or above which the file is a violation. |
| `message` | body's first paragraph | What judgelint prints for a violation. |
| `id` | file name | Rule id. |

The model sees only the question, `yes_means`, `no_means`, and the file (its
path and contents). The body, message, severity, and threshold are yours.

Each file is one request carrying every rule that governs it, so a file's
verdicts never depend on which files ran beside it. The answer is the
probability of yes, turned into a violation probability by `fail_when`: at or
above `threshold` it's a violation, at or above `warn_at` it's uncertain
(reported, never fails), and below that it passes.

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
wrong, with the probability it gave:

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

## Configuration

`.judgelint.yml`:

```yaml
provider: typesafe        # see `judgelint providers`
model: jev-latest         # defaults to the provider's
threshold: 0.7            # violation probability that counts as a violation
warn_at: 0.4              # at least this, but below threshold, is reported as uncertain
rules: .judgelint/rules
cache: .judgelint/cache.json   # or false
max_bytes: 60000          # larger files are reported as skipped, never passed
timeout: 30
retries: 2                # for 408, 429, 5xx, and 529, honoring Retry-After
```

Command-line flags override the file: `--provider`, `--model`, `--threshold`,
`--no-cache`, `--config`, `--format json`. Choosing a different provider on the
command line drops the file's provider settings (model, api_base, and so on),
so `judgelint test --provider openai` asks OpenAI for its own default model.

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

Each answer is cached under a hash of the state the model saw, the rule's
question and criteria, and the model. Editing the file, rewording the rule, or
switching models is a miss; changing a threshold or severity is not, because
the model never saw them. Commit the cache to share answers across machines
and CI.

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
`/etc/pki/tls/certs/ca-bundle.crt`). Through the gem it starts in about 45 ms,
against about 110 ms in plain Ruby; run directly, a few milliseconds. The
[Native gems](.github/workflows/native.yml) workflow builds and tests the four
platform gems. There's no native Windows build: Spinel's Windows port is
best-effort, and the Ruby gem already runs there.

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
