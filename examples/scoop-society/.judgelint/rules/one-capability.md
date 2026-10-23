---
question: "Do the files in this directory serve more than one unrelated purpose?"
yes_means: "Some files serve a second, unrelated capability, or are kept around for a retired one."
no_means: "Every file serves the one capability the feature is named for."
scope: "directory"
paths: ["src/features/*"]
context: ["src/domain/types.ts", "src/store/memory-store.ts"]
---
One capability per feature.
