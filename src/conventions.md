---
paths: ["**/*.rb"]
excludes: ["test/**", "spec/**"]
---
# Ruby conventions

- **No silent rescues.** A rescue logs the error, re-raises it, or turns it
  into a result the caller sees. Swallowed exceptions hide bugs until they
  cost us data.

  Bad:

  ```ruby
  def fetch_profile(id)
    client.profile(id)
  rescue StandardError
    nil
  end
  ```

  Good:

  ```ruby
  def fetch_profile(id)
    client.profile(id)
  rescue Client::Timeout => e
    logger.warn("profile #{id} timed out: #{e.message}")
    raise
  end
  ```

- **Error messages say what to do next.** A raised error names what was
  wrong and what would work instead.

  Bad:

  ```ruby
  raise ArgumentError, "invalid plan"
  ```

  Good:

  ```ruby
  raise ArgumentError, "unknown plan #{plan.inspect}; use one of #{PLANS.keys.join(', ')}"
  ```
