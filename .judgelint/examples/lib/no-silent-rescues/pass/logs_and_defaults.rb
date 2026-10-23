def exchange_rate(currency)
  rates_client.fetch(currency)
rescue RatesClient::Unavailable => e
  Rails.logger.error("rates unavailable for #{currency}: #{e.message}")
  ErrorTracker.notify(e)
  DEFAULT_RATES.fetch(currency)
end
