# frozen_string_literal: true

require "rake/testtask"
require "rubygems/package"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

SPINEL = ENV.fetch("SPINEL", "spinel")
BINARY = "build/judgelint"

# Spinel links OpenSSL dynamically from wherever it found it at build time,
# which other machines won't have. This compiles Spinel's C with the same
# ingredients but OpenSSL's static archives, so the binary needs only libc.
desc "Compile the native binary with Spinel (set SPINEL to its path if it isn't on PATH)"
task :spinel do
  mkdir_p "build"
  build = `#{SPINEL} -I lib exe/judgelint --print-build`.lines.map { |line| line.chomp.split(" ", 2) }
  abort "spinel --print-build failed" unless $?.success?

  libdirs = build.filter_map { |kind, value| value.delete_prefix("-L") if kind == "lib" && value.start_with?("-L") }
  args = build.flat_map do |kind, value|
    case kind
    when "cflag", "define" then [value]
    when "include" then ["-I#{value}"]
    when "link", "runtime" then [value]
    when "lib"
      library = value[/\A-l(ssl|crypto)\z/, 1]
      next [] if value.start_with?("-L")
      next [value] unless library

      # Where Spinel found OpenSSL, pkg-config's or Homebrew's OpenSSL, or
      # wherever the compiler would look (on Linux, the system's libssl-dev).
      dirs = libdirs + [`pkg-config --variable=libdir openssl 2>/dev/null`.strip,
                        "#{`brew --prefix openssl@3 2>/dev/null`.strip}/lib"]
      found = `#{ENV.fetch('CC', 'cc')} -print-file-name=lib#{library}.a`.strip
      candidates = dirs.reject(&:empty?).map { |dir| File.join(dir, "lib#{library}.a") } + [found]
      static = candidates.find { |path| File.file?(path) }
      abort "No static lib#{library}.a in #{candidates.join(', ')}" unless static
      [static]
    else []
    end
  end
  args += %w[-lpthread -ldl] if RUBY_PLATFORM.include?("linux")

  sh SPINEL, "-I", "lib", "exe/judgelint", "-c", "-o", "build/judgelint.c", "--force"
  sh ENV.fetch("CC", "cc"), "-O2", "-w", "build/judgelint.c", *args.reject { |arg| arg.end_with?(".c") }, "-o", BINARY
  sh "strip", BINARY
end

desc "Run the end-to-end tests against the Spinel binary too"
task "test:spinel" => :spinel do
  ENV["JUDGELINT_BINARY"] = File.expand_path(BINARY)
  Rake::Task[:test].invoke
end

desc "Build the plain Ruby gem into pkg/"
task :gem do
  mkdir_p "pkg"
  spec = Gem::Specification.load("judgelint.gemspec")
  mv Gem::Package.build(spec), "pkg/"
end

desc "Build this platform's gem, with the native binary in libexec/, into pkg/"
task "gem:native" => :spinel do
  mkdir_p "libexec"
  cp BINARY, "libexec/judgelint"
  spec = Gem::Specification.load("judgelint.gemspec")
  # arm64-darwin, not arm64-darwin-24: without the OS version, any release
  # since the one the binary was built for can install it.
  spec.platform = Gem::Platform.new([Gem::Platform.local.cpu, Gem::Platform.local.os])
  spec.files += ["libexec/judgelint"]
  mkdir_p "pkg"
  mv Gem::Package.build(spec), "pkg/"
ensure
  rm_rf "libexec"
end

task default: :test
