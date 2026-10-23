---
question: "Do the describe and it names fail to read as a sentence naming the module, the situation, and one outcome?"
yes_means: "The top-level describe isn't the module name, nested describes aren't when clauses, or an it doesn't state one observable outcome."
no_means: "describe(module) > describe(when ...) > it(outcome) reads as a sentence."
paths: ["tests/*.test.ts"]
---
describe + it reads as a sentence.
