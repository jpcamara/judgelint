---
question: "Not counting type and interface declarations, does this module export any function or value other than one function named run?"
yes_means: "It exports a helper function, a constant, or an entry point with another name."
no_means: "The only function it exports is run. Exported types and interfaces don't count."
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
A service exports exactly one entry point, run.
