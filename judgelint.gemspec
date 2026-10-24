# frozen_string_literal: true

require_relative "lib/judgelint/version"

Gem::Specification.new do |spec|
  spec.name = "judgelint"
  spec.version = Judgelint::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Checks code against conventions written in plain English, using decision models."
  spec.description = <<~TEXT
    judgelint checks code against conventions you write as bullets in a README.
    It asks a decision model, such as TypeSafe's Jev, whether each file breaks
    each bullet, and reports violations with line numbers. On macOS and Linux
    the gem includes a native binary.
  TEXT
  spec.homepage = "https://github.com/jpcamara/judgelint"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # lib/rubygems_plugin.rb ships only in the platform gems (see the Rakefile).
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE"] - ["lib/rubygems_plugin.rb"]
  spec.bindir = "exe"
  spec.executables = ["judgelint"]
end
