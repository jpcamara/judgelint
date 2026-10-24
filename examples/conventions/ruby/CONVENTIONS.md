---
paths: ["app/**/*.rb", "lib/**/*.rb"]
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

- **Service objects return a Result.** A service's `call` returns
  `Result.success(value)` or `Result.failure(error)`, never a bare value,
  `nil`, or `false`.

  Bad:

  ```ruby
  class ActivateAccount
    def call(account)
      return false if account.suspended?

      account.update!(active: true)
      account
    end
  end
  ```

  Good:

  ```ruby
  class ActivateAccount
    def call(account)
      return Result.failure(:suspended) if account.suspended?

      account.update!(active: true)
      Result.success(account)
    end
  end
  ```

- **Jobs take ids, not records.** Arguments to `perform_later` are ids and
  plain values. A record can change or disappear before the job runs.

  Bad:

  ```ruby
  WelcomeEmailJob.perform_later(user)
  ```

  Good:

  ```ruby
  WelcomeEmailJob.perform_later(user.id, locale: user.locale)
  ```

- **Error messages say what to do next.** A raised error names what was wrong
  and what would work instead.

  Bad:

  ```ruby
  raise ArgumentError, "invalid plan"
  ```

  Good:

  ```ruby
  raise ArgumentError, "unknown plan #{plan.inspect}; use one of #{PLANS.keys.join(', ')}"
  ```
