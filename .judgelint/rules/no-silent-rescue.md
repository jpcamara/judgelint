---
question: Does this code rescue an exception and then carry on as if nothing happened?
yes_means: A rescue neither logs the error, re-raises it, nor returns an explicit failure to the caller.
no_means: Every rescue logs, re-raises, retries before eventually raising, or turns the error into a result the caller sees. Code with no rescue counts as no.
paths: ["lib/**/*.rb", "exe/*", "spinel/*.rb"]
excludes: ["lib/judgelint/scaffold.rb"]
---
Swallowed exceptions hide bugs until they cost us data.

judgelint's own rule, run on judgelint. scaffold.rb is excluded because it
holds the init example's bad code as a string.
