# frozen_string_literal: true

# Ships only in judgelint's platform gems, which carry the native binary in
# libexec/. After installing one, point the judgelint command straight at the
# binary instead of at RubyGems' Ruby wrapper, which spends about 40 ms
# loading Ruby and RubyGems before it gets there.
Gem.post_install do |installer|
  next unless installer.spec.name == "judgelint"

  native = File.join(installer.spec.full_gem_path, "libexec", "judgelint")
  command = File.join(installer.bin_dir, "judgelint")
  next unless File.executable?(native) && File.file?(command)

  File.delete(command)
  File.symlink(native, command)
end
