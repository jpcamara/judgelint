# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

SPINEL = ENV.fetch("SPINEL", "spinel")
BINARY = "build/judgelint"

desc "Compile the native binary with Spinel (set SPINEL to its path if it isn't on PATH)"
task :spinel do
  mkdir_p "build"
  sh SPINEL, "-I", "lib", "exe/judgelint", "-o", BINARY
end

desc "Run the end-to-end tests against the Spinel binary too"
task "test:spinel" => :spinel do
  ENV["JUDGELINT_BINARY"] = File.expand_path(BINARY)
  Rake::Task[:test].invoke
end

task default: :test
