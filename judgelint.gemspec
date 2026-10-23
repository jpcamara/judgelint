# frozen_string_literal: true

require_relative "lib/judgelint/version"

Gem::Specification.new do |spec|
  spec.name = "judgelint"
  spec.version = Judgelint::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Lint for conventions a linter can't check, judged by System One decision models."
  spec.description = <<~TEXT
    judgelint checks files against conventions that only a reader can judge. Each
    rule is a yes/no question answered by a fast decision model such as TypeSafe's
    Jev over the System One protocol. It also compiles to a native binary with
    Spinel.
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
