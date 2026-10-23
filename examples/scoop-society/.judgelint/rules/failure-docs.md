---
question: "Does the service have a doc comment that states its purpose in one sentence and lists its domain failure modes?"
yes_means: "A doc comment with a one-sentence purpose and every domain failure the service returns."
no_means: "No doc comment, or one that leaves out the purpose or the failure modes."
fail_when: "no"
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
Every service documents its purpose and failure modes.
