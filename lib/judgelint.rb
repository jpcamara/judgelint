# frozen_string_literal: true

require "json"
require "yaml"
require "digest"
require "fileutils"
require "net/https"
require "open3"

require_relative "judgelint/version"
require_relative "judgelint/errors"
require_relative "judgelint/glob"
require_relative "judgelint/rule"
require_relative "judgelint/spec"
require_relative "judgelint/source"
require_relative "judgelint/question"
require_relative "judgelint/changes"
require_relative "judgelint/providers"
require_relative "judgelint/config"
require_relative "judgelint/cache"
require_relative "judgelint/usage"
require_relative "judgelint/pool"
require_relative "judgelint/verdict"
require_relative "judgelint/protocol"
require_relative "judgelint/client"
require_relative "judgelint/runner"
require_relative "judgelint/paint"
require_relative "judgelint/reporter"
require_relative "judgelint/scaffold"
require_relative "judgelint/cli"

# Lints files against conventions that only a reader can check. Each rule is a
# yes/no question that a System One decision model answers with a probability.
module Judgelint
  NUMBER = /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/

  # Float(), without the rescue: answers nil for anything that isn't a number.
  def self.number(value)
    string = value.to_s.strip
    NUMBER.match?(string) ? string.to_f : nil
  end

  def self.read_yaml(path, required:)
    return parse_yaml(File.read(path), path) if File.exist?(path)
    raise ConfigError, "No config file at #{path}" if required

    {}
  end

  def self.parse_yaml(yaml, path)
    data = YAML.safe_load(yaml) || {}
    raise ConfigError, "#{path} must be a mapping" unless data.is_a?(Hash)

    data
  rescue Psych::AliasesNotEnabled
    raise ConfigError, "#{path}: YAML aliases aren't supported"
  rescue Psych::Exception => e
    # Bad syntax, or a tag naming a class safe_load won't build.
    raise ConfigError, "#{path}: #{e.message}"
  end
end
