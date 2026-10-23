---
question: "Does any it block contain more than one expect?"
yes_means: "An it block asserts two or more outcomes with separate expect calls."
no_means: "Every it block has exactly one expect."
paths: ["tests/*.test.ts"]
---
Every it block contains exactly one expect.
