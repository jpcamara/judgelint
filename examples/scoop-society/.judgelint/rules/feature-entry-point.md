---
question: "Is this feature directory missing an index.ts that re-exports its public API?"
yes_means: "There is no index.ts in the directory."
no_means: "The directory has an index.ts that re-exports the feature's API."
scope: "directory"
paths: ["src/features/*"]
context: ["src/domain/types.ts", "src/store/memory-store.ts"]
---
A feature has exactly one entry point, index.ts.
