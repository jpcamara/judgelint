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
  The README describes it under "CI", and
  `test_a_finding_on_a_line_the_change_didnt_touch_passes` and
  `a_change_counts_only_the_share_of_where_on_its_lines` cover it.

## Reviews

A review finding is fixed when it's a crash, a security hole, or a simpler
way to write the same thing. A finding that would change what users see,
or adds handling for a new case, is listed for the maintainer, not built.

Before calling behavior a bug, check the README, the CHANGELOG and this
file for whether it was chosen. If a test asserts it, assume it was. Don't
change or delete a test to make a fix pass without saying so.
