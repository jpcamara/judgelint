---
paths: ["lib/**/*.rb", "exe/*"]
excludes: ["lib/judgelint/scaffold.rb"]
---
# Conventions for judgelint's code

judgelint checks itself against these with `bundle exec exe/judgelint`, and
`bundle exec exe/judgelint test` judges the examples in
`.judgelint/examples/lib/`. `scaffold.rb` is excluded because it holds the
`init` example's bad code as a string.

- **No silent rescues.** A rescue logs the error, re-raises it, retries before
  eventually raising, or turns it into a result the caller sees. Swallowed
  exceptions hide bugs until they cost us data.
