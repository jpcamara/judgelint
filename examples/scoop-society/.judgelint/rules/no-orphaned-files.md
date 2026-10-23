---
question: "Is any file in this directory unreachable from index.ts through its imports?"
yes_means: "A file that index.ts doesn't import, directly or through other files in the feature, or a directory with no index.ts at all."
no_means: "Every file is imported, directly or indirectly, by index.ts."
scope: "directory"
paths: ["src/features/*"]
context: ["src/domain/types.ts", "src/store/memory-store.ts"]
---
Every file in a feature is reachable from index.ts.
