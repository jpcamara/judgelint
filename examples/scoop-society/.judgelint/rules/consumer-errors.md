---
question: "Does this service return or throw a vague error message, one that doesn't tell the caller what to send instead?"
yes_means: "A message like \"invalid input\", \"no\", or \"opensAt failed the regex\" that leaves the caller guessing."
no_means: "Each message names the problem and what would work instead, like \"rating must be a whole number from 1 to 5\". A service with no error messages counts as no."
paths: ["src/services/*.ts"]
excludes: ["src/services/legacy-import.ts", "src/services/_*"]
---
Error messages name what was wrong and what would be accepted instead.
