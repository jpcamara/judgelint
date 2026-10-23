---
question: "Is the file name on the Path line verb-first kebab-case that says what the service does, like create-review.ts or rank-parlors.ts?"
yes_means: "The name starts with a verb."
no_means: "The name is a noun or doesn't say what the service does."
fail_when: "no"
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
Module names are verb-first kebab-case.
