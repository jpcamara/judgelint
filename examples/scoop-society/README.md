# Scoop Society

A small TypeScript API for ice cream parlor reviews. Its conventions are
written as three README specs, and some of the code breaks them on purpose.
Each top-level bullet is a rule, 22 in all:

| Spec | Covers | Rules |
|---|---|---|
| [src/services/README.md](src/services/README.md) | each service file | 8 |
| [src/features/README.md](src/features/README.md) | each feature directory, with the domain types and store as context | 6 |
| [tests/README.md](tests/README.md) | each test file | 8 |

[.judgelint.yml](.judgelint.yml) ignores underscore files and generated
files.

## Results

[expected.json](expected.json) lists the 14 known violations. Thirteen come
from praxis's own review of the app. The other is `update-parlor-hours.ts`,
which builds `summary` and `label` before validating its input.

With Jev and the specs as written, judgelint finds 12 of the 14, with no false
positives and 9 to 11 uncertain findings. A run is 20 requests and costs about
$0.003.

It misses two rules in `src/features/flavor-of-day`:

- **No orphaned files.** This scores about 0.6, so it's reported as uncertain.
  The feature has no `index.ts`, and it takes more reasoning than a decision
  model does to conclude its files are orphans.
- **One capability per feature.** This scores about 0.2. `old-rotation.ts` is
  an older version of the rotation, so it's arguable whether it counts as a
  second capability.

## Each model

These runs use each model on its own, first with the specs as written and then
with `violation:` and `compliant:` lines added under every bullet. The added
lines were written in general terms for this test and aren't committed.
Counts are out of 14.

| Model | As written: found, extra, uncertain | With criteria: found, extra, uncertain | Cost |
|---|---|---|---|
| Jev (`typesafe`) | 12, 0, 10 | 13, 3, 7 | $0.003 |
| Jev 1.14 (`typesafe:jev-preview`) | 12, 1, 12 | 13, 3, 7 | $0.003 |
| Jev via `openrouter` | 12, 0, 10 | 13, 0, 8 | $0.003 |
| Clef (`cloudflare`) | 11, 0, 4 | 13, 2, 5 | $0.02 |
| Clef Flash | 8, 3, 13 | 11, 8, 15 | |
| Celeris 1.0 | 7, 0, 5 | 13, 3, 2 | $0.003 |
| Celeris 1.1 | 6, 0, 6 | 13, 3, 2 | |
| GPT-6 Luna (`openai`) | 13, 11, 6 | 14, 8, 9 | $0.01 |
| Kev 4B | 6, 2, 21 | 11, 3, 17 | $0.003 |
| Jev and Clef averaged | 12, 0, 4 | 13, 1, 8 | $0.02 |

Each row is one run, except Jev as written, which ran twice. Some of the extra
findings are fair calls that praxis didn't make. For example, `parlor.ts` both
ranks and formats parlors.

The criteria help most when a model isn't sure what a bullet means. Celeris
goes from 7 to 13 found. Loose criteria also add false positives, which is
why it's worth testing rules against examples.

## Running it

The answers are cached in `.judgelint/cache.json`, so running `judgelint` in
this directory replays them without an API key. `rake example` asks Jev again
and compares the result with `expected.json`. `test/example_test.rb` replays
the cache through the gem and the binary and checks the same thing.

## Credits

The app and its specs come from [praxis](https://github.com/zarpay/praxis-cli)
at commit `02a4bbd`, under its MIT license ([LICENSE.praxis](LICENSE.praxis)).
