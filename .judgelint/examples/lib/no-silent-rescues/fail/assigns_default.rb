def load_settings
  @settings = JSON.parse(File.read(SETTINGS_PATH))
rescue StandardError => e
  @settings = {}
end
