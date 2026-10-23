---
question: "Does this service validate its input before doing any work?"
yes_means: "Validation comes first and reads top to bottom before the happy path begins."
no_means: "Work starts before validation, or validation is interleaved with the happy path."
fail_when: "no"
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
Input is validated before any work happens.
