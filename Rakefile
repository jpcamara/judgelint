# frozen_string_literal: true

require "rake/testtask"
require "rubygems/package"
require "json"

BINARY = "target/release/judgelint"

desc "Build the binary with Cargo"
task :build do
  sh "cargo", "build", "--release", "--locked"
end

desc "Run the Rust unit tests"
task "test:unit" do
  sh "cargo", "test", "--release", "--locked"
end

desc "Run the end-to-end tests against the binary (JUDGELINT_BINARY, or a fresh build)"
Rake::TestTask.new("test:cli") do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
end
task "test:cli" => :build unless ENV["JUDGELINT_BINARY"]

desc "Run every test"
task test: ["test:unit", "test:cli"]

desc "Build the plain gem, for platforms without a binary, into pkg/"
task :gem do
  mkdir_p "pkg"
  spec = Gem::Specification.load("judgelint.gemspec")
  mv Gem::Package.build(spec), "pkg/"
end

desc "Build this platform's gem, with the binary in libexec/, into pkg/"
task "gem:native" => :build do
  mkdir_p "libexec"
  cp BINARY, "libexec/judgelint"
  spec = Gem::Specification.load("judgelint.gemspec")
  # arm64-darwin, not arm64-darwin-24: without the OS version, any release
  # since the one the binary was built for can install it.
  spec.platform = Gem::Platform.new([Gem::Platform.local.cpu, Gem::Platform.local.os])
  spec.files += ["libexec/judgelint", "lib/rubygems_plugin.rb"]
  mkdir_p "pkg"
  mv Gem::Package.build(spec), "pkg/"
ensure
  rm_rf "libexec"
end

desc "Re-ask the model about examples/scoop-society and check it against praxis's verdicts"
task example: :build do
  binary = File.expand_path(BINARY)
  Dir.chdir("examples/scoop-society") do
    rm_f ".judgelint/cache.bin"
    out = `#{binary} --format json`
    found = JSON.parse(out)["results"].select { |result| result["status"] == "violation" }
                                     .map { |result| [result["path"], result["rule"]] }.sort
    spec = JSON.parse(File.read("expected.json"))
    pairs = ->(list) { list.map { |violation| [violation["path"], violation["rule"]] } }
    expected = (pairs.call(spec["violations"]) - pairs.call(spec["missed"])).sort
    arguable = pairs.call(spec["arguable"])
    extra = found - expected - arguable
    abort "Missed: #{(expected - found).inspect}\nExtra: #{extra.inspect}" unless (expected - found).empty? && extra.empty?
    puts "All #{expected.size} expected violations found (#{spec['missed'].size} known misses), " \
         "#{(found & arguable).size} of #{arguable.size} arguable ones, and nothing else."
  end
end

task default: :test
