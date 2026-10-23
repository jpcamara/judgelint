# frozen_string_literal: true

# Entry point for the native binary: `rake spinel` compiles this with Spinel.
require_relative "../lib/judgelint"

exit Judgelint::CLI.new(ARGV).run
