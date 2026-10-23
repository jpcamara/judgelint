# Scoop Society: praxis's demo, judged by judgelint

Scoop Society is the demo app from [praxis](https://github.com/zarpay/praxis-cli)
(commit `02a4bbd`): a small TypeScript API for ice cream parlor reviews, with
conventions a linter can't check written up as three README specs, and code
that breaks some of them on purpose. The code and the specs are praxis's,
under its MIT license; see [LICENSE.praxis](LICENSE.praxis).

judgelint reads those READMEs unchanged. Every top-level bullet becomes a rule,
22 in all:

| Spec | Governs | Rules |
|---|---|---|
| [src/services/README.md](src/services/README.md) | each service file | 8 |
| [src/features/README.md](src/features/README.md) | each feature directory (`cohort: by_directory`), with `src/domain/types.ts` and `src/store/memory-store.ts` as context | 6 |
| [tests/README.md](tests/README.md) | each test file | 8 |

The only judgelint-specific file is [.judgelint.yml](.judgelint.yml), which
ignores underscore files and generated files, as praxis does.

## Against praxis's verdicts

[expected.json](expected.json) lists every violation praxis's reviewer (Mercury
2.5, a chat model) recorded, plus one it missed, and the two judgelint misses:

| | |
|---|---|
| Violations praxis recorded, plus one it missed | 14 |
| Found by judgelint | 12 |
| Found by judgelint and not expected | 0 |
| Uncertain findings (reported, never failing) | 9 to 11 |
| Cost of a run | 20 requests, about 63,000 input tokens, $0.0026 |

The one praxis missed: `update-parlor-hours.ts` builds `summary` and `label`
(lines 11-13) before it validates anything, which breaks "input is validated
before any work happens."

The two judgelint misses, both in `src/features/flavor-of-day`:

- **"No orphaned files: every file in the directory is reachable from
  `index.ts`."** It scores about 0.6, uncertain. The feature has no `index.ts`
  at all, and getting from there to "so its files are orphans" takes more
  reasoning than a decision model does.
- **"One capability per feature."** It scores about 0.2. `old-rotation.ts` is
  the feature's earlier rotation, so whether it's a second capability is
  arguable.

When a bullet needs more than the model can do, give it criteria, or write
that one rule as a precise question (see the main README). An earlier version
of this example wrote 13 of praxis's conventions as questions, by hand, and
found all 13 violations it was checked against, the orphaned file included.

## Models, one at a time

The same specs on each model, once as praxis wrote them and once with
`violation:` and `compliant:` lines added under every bullet (written for
this comparison, general rather than aimed at this code; not committed).
"Arguable" extras are violations praxis didn't record that a reader could
call either way: `awards` names its types file `award-types.ts` rather than
`awards-types.ts`, `parlor.ts` both ranks and formats, and `apply-refund.ts`
reads the store before checking the amount.

| Model | As written: found, extras, uncertain | With criteria: found, extras (arguable), uncertain | Cost |
|---|---|---|---|
| Jev (`typesafe`) | 12, 0, 10 | 13, 3 (2), 7 | $0.003 |
| Jev 1.14 (`typesafe:jev-preview`) | 12, 1, 12 | 13, 3 (2), 7 | $0.003 |
| Jev via `openrouter` | 12, 0, 10 | 13, 0, 8 | $0.003 |
| Clef (`cloudflare`) | 11, 0, 4 | 13, 2 (1), 5 | $0.02 |
| Clef Flash | 8, 3, 13 | 11, 8 (1), 15 | |
| Celeris 1.0 | 7, 0, 5 | 13, 3 (1), 2 | $0.003 |
| Celeris 1.1 | 6, 0, 6 | 13, 3 (1), 2 | |
| GPT-6 Luna (`openai`) | 13, 11, 6 | 14, 8 (2), 9 | $0.01 |
| Kev 4B | 6, 2, 21 | 11, 3, 17 | $0.003 |
| Jev and Clef averaged | 12, 0, 4 | 13, 1 (1), 8 | $0.02 |

One run each (two for Jev as written), out of 14 expected violations.
Criteria help most where a model is unsure what a bullet means: Celeris goes
from 7 to 13 found. They cost precision when they're loose; the extras that
aren't arguable are a criterion's wording read more broadly than meant, which
is what examples are for. Jev as written, with no criteria and no second
model, finds 12 with none extra; that's what this example records.

## Running it

The answers are cached in `.judgelint/cache.json`, so `judgelint` here replays
without a key or a network. `rake example` re-asks Jev and checks the result
against `expected.json`; the test suite (`test/example_test.rb`) replays the
cache through the gem and the native binary and checks the same thing.
