# Convention examples

Complete specs to copy from. Each folder has a `CONVENTIONS.md` with `Bad:`
and `Good:` examples under every rule, and a little code that breaks some of
the rules.

| Folder | Covers |
|---|---|
| [ruby](ruby/CONVENTIONS.md) | Rescues, service results, job arguments, error messages |
| [typescript](typescript/CONVENTIONS.md) | React components: data fetching, `any`, translated text |
| [python](python/CONVENTIONS.md) | Timeouts, logging, documented exceptions |
| [sql](sql/CONVENTIONS.md) | Postgres migrations: concurrent indexes, safe columns, rollbacks |

Run them from inside a folder:

```sh
cd examples/conventions/ruby
judgelint test   # judges the Bad and Good examples in CONVENTIONS.md
judgelint        # checks the code in app/
```

With Jev, every example is judged correctly, and the code has these
violations and no others:

| Folder | File | Rule |
|---|---|---|
| ruby | `app/jobs/sync_invoices_job.rb` | No silent rescues; jobs take ids, not records |
| ruby | `app/services/charge_card.rb` | Service objects return a Result |
| typescript | `src/components/Banner.tsx` | Text users see goes through `t()` |
| typescript | `src/components/ProfileCard.tsx` | Components don't fetch |
| python | `src/pipeline/clean.py` | Log, don't print |
| python | `src/pipeline/export.py` | Network calls have a timeout |
| sql | `db/migrations/20261025_add_carrier.sql` | All three rules |

`charge_card.rb` is also reported as uncertain for "No silent rescues", at
about 0.56. It rescues a gateway error, logs it, and returns `false`, which
breaks the Result rule more clearly than the rescue rule.

The first draft of the `t()` rule flagged `<h2>{user.name}</h2>` in
`ProfileCard.tsx`. Adding "Values from data, like `user.name`, aren't text we
write" to the bullet fixed it.

The answers are cached in each folder's `.judgelint/cache.bin`, so both
commands replay without an API key. `test/example_test.rb` checks the results
above.
