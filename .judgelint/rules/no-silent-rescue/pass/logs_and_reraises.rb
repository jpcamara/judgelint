def fetch_profile(id)
  client.profile(id)
rescue Client::Timeout => e
  logger.warn("profile #{id} timed out: #{e.message}")
  raise
end
