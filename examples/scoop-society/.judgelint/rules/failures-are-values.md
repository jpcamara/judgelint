---
question: "Does this service throw an exception for a failure a caller could cause, such as bad input or a missing record, instead of returning { ok: false, error }?"
yes_means: "A throw for invalid input, a missing record, or another caller-caused failure."
no_means: "Caller-caused failures are returned as { ok: false, error }; throw appears only for programmer error, or not at all."
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
Domain failures are values, never exceptions.
