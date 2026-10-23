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

judgelint is written in Ruby. It uses RubyLLM's Judge API (RubyLLM 2.1+) and
also compiles to a native binary with [Spinel](https://github.com/matz/spinel).

## Install

```sh
gem install judgelint
```

Or build the native binary (see [Native binary](#native-binary)).

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

(That's judgelint's first run on itself. The cache really did turn a corrupt
file into an empty cache without saying so; it raises now. `scaffold.rb` holds
the `init` example's bad code as a string, and is excluded.)

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
convention is too broad for one question. That run is Jev on this repo's own
rule. Adding "retries before eventually raising" to `no_means` took it to
10/10; see [.judgelint/rules](.judgelint/rules). The model is shown each example's
path relative to its `pass/` or `fail/` directory, so the directory name never
leaks the answer.

## Configuration

`.judgelint.yml`:

```yaml
provider: typesafe        # typesafe (Jev), celeris, openrouter (Kev), or any RubyLLM provider
model: jev-latest
backend: auto             # auto, ruby_llm, or system_one
threshold: 0.7            # violation probability that counts as a violation
warn_at: 0.4              # at least this, but below threshold, is reported as uncertain
rules: .judgelint/rules
cache: .judgelint/cache.json   # or false
max_bytes: 60000          # larger files are reported as skipped, never passed
batch_size: 32            # questions per request
timeout: 30
# api_base: https://api.typesafe.ai
# api_key_env: TYPESAFE_API_KEY
# provider_options: { x_celeris: { explain: true } }   # merged into the request body
# require: [ruby_llm/llm_judge]                         # extra RubyLLM providers
```

Command-line flags override the file: `--provider`, `--model`, `--backend`,
`--threshold`, `--no-cache`, `--config`, `--format json`.

### Providers

| `provider` | Model | Key | Notes |
|---|---|---|---|
| `typesafe` | `jev-latest` | `TYPESAFE_API_KEY` | Default. ~200 ms per request. |
| `celeris` | `celeris-1-decision` | `CELERIS_API_KEY` | Best calibrated in our benchmarks. Not deterministic between runs. |
| `openrouter` | `jaredpalmer/kev-4b` | `OPENROUTER_API_KEY` | Kev 4B through OpenRouter's System One endpoint. |
| anything else | required | set `api_key_env` | Passed to RubyLLM as the provider name. Needs the `ruby_llm` backend. |

### Backends

- `ruby_llm` calls `RubyLLM.judge`. It is the default on CRuby and the way to
  reach any provider RubyLLM supports, including chat-model judges such as
  [ruby_llm-llm_judge](https://github.com/jpcamara/ruby_llm-llm_judge) for
  rules a decision model can't handle.
- `system_one` posts the System One protocol directly over `Net::HTTP`. The
  native binary always uses it, since Spinel can't load RubyLLM. Both send the
  same request body.

### Cache

Each answer is cached under a hash of the state the model saw, the rule's
question and criteria, and the model. Editing the file, rewording the rule, or
switching models is a miss; changing a threshold or severity is not, because
the model never saw them. Commit the cache to share answers across machines
and CI.

## How it works

For each file, judgelint collects the rules whose globs match it and sends one
request with every rule as its own question. The state is the file's path and
contents. Each answer is the probability of "yes", which becomes a violation
probability through `fail_when` and then a verdict through the thresholds:

- at or above `threshold`: violation
- at or above `warn_at`: uncertain (reported, never fails)
- below `warn_at`: pass

Files are never batched together, so one file's verdict never depends on
which files ran beside it.

## Native binary

judgelint is written in the subset of Ruby that Spinel compiles. The same
source runs on CRuby and as a native binary:

```sh
git clone https://github.com/matz/spinel && (cd spinel && make deps && make)
SPINEL=../spinel/bin/spinel rake spinel     # writes build/judgelint
SPINEL=../spinel/bin/spinel rake test:spinel   # runs the CLI tests against it too
```

The binary uses Spinel's `net/https`, which links the OpenSSL it was built
against (Homebrew's `openssl@3` on macOS). It starts in a few milliseconds,
against about 250 ms for the gem with RubyLLM loaded, so a fully cached run
is effectively free.

Writing for Spinel meant a few choices that look odd in CRuby:

- Value objects are plain classes, not `Data.define`. Spinel can't compile a
  Data or Struct in a program that also uses `net/https` and `json`.
- Options are parsed by hand. Spinel can't compile this program's use of OptionParser.
- `Hash#fetch` with a Float default on a YAML-loaded Hash is avoided; Spinel
  miscompiles it.
- No `method_missing`, `eval`, or runtime `define_method`. The RubyLLM backend
  is loaded behind `RUBY_ENGINE != "spinel"`, which Spinel drops at compile time.

## Development

```sh
bundle install
bundle exec rake test
```

## License

MIT
