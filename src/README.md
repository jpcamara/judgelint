---
paths: ["src/**/*.rs"]
---
# Conventions for judgelint's code

judgelint checks itself against these with `judgelint`, and `judgelint test`
judges the examples in `.judgelint/examples/src/`.

- **No silently dropped errors.** An error is returned with `?`, logged,
  retried before it's returned, or turned into a result the caller sees.
  `let _ =`, `.ok()` and `unwrap_or_default()` on a `Result` hide failures
  until they cost us data. A `Result` that can't fail, like writing to a
  `String`, and removing a temporary file may be ignored.
