# frozen_string_literal: true

module Judgelint
  class Error < StandardError; end

  # The command line doesn't parse.
  class UsageError < Error; end

  # A rule file or the config file can't be used as written.
  class ConfigError < Error; end

  # The decision model couldn't be reached or answered with something unusable.
  class ApiError < Error; end
end
