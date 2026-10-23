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
ignores underscore files and generated files as praxis does, and asks each
question three times (`repeat: 3`) to steady the borderline answers.

## Against praxis's verdicts

[expected.json](expected.json) lists every violation praxis's reviewer (Mercury
2.5, a chat model) recorded, plus one it missed, and the two judgelint misses:

| | |
|---|---|
| Violations praxis recorded, plus one it missed | 14 |
| Found by judgelint | 12 |
| Found by judgelint and not expected | 0 |
| Cost of a run | 60 requests, about 114,000 input tokens, $0.0048 |

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

When a bullet needs more than the model can do, write that one rule as a
precise question with criteria (see the main README's "Precise rules"). An
earlier version of this example wrote 13 of praxis's conventions that way, by
hand, and found all 13 violations it was checked against, the orphaned file
included. Asking the bullets as written gets 12 of 14 with nothing to write.

Uncertain findings (15 in the cached run) are reported but never fail a run.
Most come from bullets that bundle several requirements, like the service
entry-point bullet, where the model is less sure.

## Running it

The answers are cached in `.judgelint/cache.json`, so `judgelint` here replays
without a key or a network. `rake example` re-asks Jev and checks the result
against `expected.json`; the test suite (`test/example_test.rb`) replays the
cache through the gem and the native binary and checks the same thing.
