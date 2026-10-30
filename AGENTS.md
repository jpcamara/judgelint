# Working on judgelint

## Decisions that look like bugs

These are on purpose. A review that flags one is wrong about it. Don't
change them; raise it with the maintainer instead.

- **A change check never fails for code the change didn't touch.** Under
  `--base` and `--pr`, the verdict is scaled by the share of the "where"
  answer on the changed lines (`changed_share` in `src/runner.rs`). A
  violation the model places on an untouched line doesn't count, so
  editing an old file can't fail it for problems already there. This has
  been the design since 0.1.6. The cost is known: a new violation next to
  an older, clearer one of the same rule can pass. It was removed once on
  a review finding and had to be put back.
  `test_a_finding_on_a_line_the_change_didnt_touch_passes` covers it.

## Before changing behavior

A review finding that changes what users see, beyond fixing a crash or a
security hole, goes to the maintainer first. Check the CHANGELOG and
README for whether the current behavior was chosen.
