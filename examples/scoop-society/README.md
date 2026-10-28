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

With Jev, judgelint finds 13 of the 14. A run is 20 requests and costs about
$0.004. Besides those, it reports 8 to 12 uncertain findings and one or two
others:

- **`parlor.ts`: services do one thing.** Scores 0.68 to 0.74. The service
  ranks parlors and formats them, so this is a fair call.
- **`notify-parlor.ts`: every service has a doc comment.** Scores 0.6 to 0.7.
  The comment lists one failure mode, but the `fetch` can fail in ways it
  doesn't list.
- **`apply-discount.ts`: every service has a doc comment.** Scores about
  0.65, and over 0.7 in some runs. This one is wrong: the doc comment is
  complete.

The miss is **one capability per feature** in `src/features/flavor-of-day`,
which scores about 0.25. `old-rotation.ts` is an older version of the
rotation, so it's arguable whether it counts as a second capability.

[expected.json](expected.json) records the miss and the two fair calls.

## Each model

One run each, with the specs as written:

| Model | Found, of 14 | Extra (fair calls) | Uncertain | Cost |
|---|---|---|---|---|
| Jev (`typesafe`) | 13 | 1 (1) | 8 to 9 | $0.004 |
| Jev 1.14 (`typesafe:jev-preview`) | 13 | 1 (1) | 10 | $0.004 |
| Jev via `openrouter` | 13 | 1 (1) | 8 | $0.004 |
| Celeris 1.0 (`celeris`) | 12 | 2 (0) | 4 | $0.004 |
| Celeris 1.1 | 12 | 2 (0) | 5 | |
| GPT-6 Luna (`openai`) | 14 | 25 (2) | 7 | $0.009 |

Luna finds everything but flags far too much. Clef wasn't rerun for this
version.

## Running it

The answers are cached in `.judgelint/cache.bin`, so running `judgelint` in
this directory replays them without an API key. `rake example` asks Jev again
and compares the result with `expected.json`. `test/example_test.rb` replays
the cache and checks the same thing.

## Credits

The app and its specs come from [praxis](https://github.com/zarpay/praxis-cli)
at commit `02a4bbd`, under its MIT license ([LICENSE.praxis](LICENSE.praxis)).
