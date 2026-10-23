def fetch_profile(id)
  client.profile(id)
rescue StandardError
  nil
end
