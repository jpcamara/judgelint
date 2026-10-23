# frozen_string_literal: true

require "json"
require "yaml"
require "digest"
require "fileutils"
require "net/https"

require_relative "judgelint/version"
require_relative "judgelint/errors"
require_relative "judgelint/glob"
require_relative "judgelint/rule"
require_relative "judgelint/rule_loader"
require_relative "judgelint/config"
require_relative "judgelint/cache"
require_relative "judgelint/verdict"
require_relative "judgelint/backends/system_one"
require_relative "judgelint/backends/ruby_llm" unless RUBY_ENGINE == "spinel"
require_relative "judgelint/backends"
require_relative "judgelint/runner"
require_relative "judgelint/fixture_runner"
require_relative "judgelint/reporter"
require_relative "judgelint/scaffold"
require_relative "judgelint/cli"

# Lints files against conventions that only a reader can check. Each rule is a
# yes/no question that a System One decision model answers with a probability.
module Judgelint
end
