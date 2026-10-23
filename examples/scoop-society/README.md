# Scoop Society: praxis's demo, judged by judgelint

Scoop Society is the demo app from [praxis](https://github.com/zarpay/praxis-cli)
(commit `02a4bbd`): a small TypeScript API for ice cream parlor reviews, with
conventions a linter can't check written up as three specs, and code that
breaks some of them on purpose. The code and the specs (`src/services/README.md`,
`src/features/README.md`, `tests/README.md`) are praxis's, under its MIT
license; see [LICENSE.praxis](LICENSE.praxis).

`.judgelint/rules/` turns each spec bullet judgelint can ask about into a
yes/no question:

| Spec | Rules | Scope |
|---|---|---|
| Services (`src/services/*.ts`) | failures-are-values, consumer-errors, validate-first, no-direct-io, one-entry-point, verb-first-name, failure-docs | each file |
| Features (`src/features/*`) | feature-entry-point, no-orphaned-files, one-capability | each directory, with `src/domain/types.ts` and `src/store/memory-store.ts` as context |
| Tests (`tests/*.test.ts`) | one-expect-per-it, test-framing, no-implementation-tests | each file |

As in praxis, `src/services/legacy-import.ts` is excluded and underscore files
like `_wip-refund.ts` aren't reviewed.

## Against praxis's verdicts

[expected.json](expected.json) lists every violation judgelint must find:
each one praxis's reviewer (Mercury 2.5) recorded, plus one it missed.
Everything else must not be a violation.

```text
$ judgelint
src/services/apply-refund.ts
  x error      consumer-errors          1-21      0.96  Error messages name what was wrong and what would be accepted instead.
  x error      failure-docs             1-21      0.98  Every service documents its purpose and failure modes.
  x error      failures-are-values      1-21      0.99  Domain failures are values, never exceptions.
  ? uncertain  validate-first           1-21      0.43  Input is validated before any work happens.
src/services/notify-parlor.ts
  x error      no-direct-io             1-32      0.95  No I/O except through the injected Store.
src/services/parlor.ts
  x error      one-entry-point          1-40      0.74  A service exports exactly one entry point, run.
  x error      verb-first-name          1-47      0.96  Module names are verb-first kebab-case.
src/services/rank-parlors.ts
  x error      consumer-errors          1-34      0.96  Error messages name what was wrong and what would be accepted instead.
src/services/update-parlor-hours.ts
  x error      consumer-errors          1-28      0.97  Error messages name what was wrong and what would be accepted instead.
  x error      failure-docs             1-28      0.98  Every service documents its purpose and failure modes.
  x error      validate-first           1-28      0.88  Input is validated before any work happens.
tests/create-review.test.ts
  ? uncertain  one-expect-per-it        41-80     0.41  Every it block contains exactly one expect.
src/features/flavor-of-day
  x error      feature-entry-point                0.85  A feature has exactly one entry point, index.ts.
  x error      no-orphaned-files                  0.84  Every file in a feature is reachable from index.ts.
  x error      one-capability                     0.82  One capability per feature.

20 files, 13 violations, 2 uncertain
judgelint: 20 requests, 33,024 input tokens, $0.0014
```

All 13 match, and nothing else is a violation. The one praxis missed:
`update-parlor-hours.ts` builds `summary` and `label` (lines 11-13) before it
validates anything, which breaks "input is validated before any work happens."

Two rules took a second wording. The first `one-entry-point` ("does this
module export anything other than a single function named run?") flagged
every service, because each also exports its input type; saying types don't
count fixed it. The first `consumer-errors` flagged services whose messages
were fine; asking about vague messages instead fixed it. That's the usual
work of writing rules for a decision model, and why rules carry examples.

## Running it

The answers are cached in `.judgelint/cache.json`, so this replays without a
key or a network. `rake example` re-asks Jev and checks the result against
`expected.json`; the test suite (`test/example_test.rb`) replays the cache and
checks the same thing.
