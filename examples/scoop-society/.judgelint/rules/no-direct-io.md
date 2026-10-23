---
question: "Does this code do I/O other than through the injected Store?"
yes_means: "It calls fetch, console, timers, or reads the clock or randomness outside one obvious place."
no_means: "All I/O goes through the injected Store; time and randomness come in as inputs."
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
No I/O except through the injected Store.
