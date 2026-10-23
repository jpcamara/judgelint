---
question: "Does this test spy on call counts, mock collaborators that have in-memory implementations, or reach into module internals?"
yes_means: "Spies, mocks of collaborators with honest in-memory versions, or assertions on internals."
no_means: "It exercises only the public API and asserts on returned values and observable state."
paths: ["tests/*.test.ts"]
---
Tests exercise behavior, not implementation.
