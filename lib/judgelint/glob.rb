# frozen_string_literal: true

module Judgelint
  # Path matching shared by rule targeting and file discovery. `**/` matches
  # zero or more directories and `{a,b}` alternates, as in Dir.glob, and a
  # trailing `/**` matches everything under a directory.
  module Glob
    FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    def self.match_any?(patterns, path)
      patterns.any? do |pattern|
        File.fnmatch?(pattern, path, FLAGS) || (pattern.end_with?("/**") && File.fnmatch?("#{pattern}/*", path, FLAGS))
      end
    end

    def self.expand(patterns)
      patterns.flat_map { |pattern| glob(pattern) }.select { |path| File.file?(path) }.uniq.sort
    end

    # Dir.glob, except that a symlink to itself is skipped. Dir.glob raises
    # ELOOP when a pattern looks inside one, so the pattern is then globbed a
    # segment at a time, entering only directories that resolve.
    def self.glob(pattern)
      Dir.glob(pattern)
    rescue Errno::ELOOP
      parts = pattern.split("/")
      found = [""]
      until parts.empty?
        part = parts.shift
        part = "#{part}/#{parts.shift}" if part == "**" && !parts.empty?
        found = found.flat_map do |dir|
          next [] unless dir.empty? || File.directory?(dir)

          Dir.glob(dir.empty? ? part : File.join(dir, part))
        end
      end
      found
    end

    # The files to check: in a git repository, those git tracks or would add,
    # so nothing it ignores (node_modules, build output) is ever read.
    # Elsewhere, every file the patterns match.
    def self.files(patterns)
      listed = project_files
      return expand(patterns) if listed.nil?

      listed.select { |path| match_any?(patterns, path) && File.file?(path) }
    end

    # nil outside a git repository, or without git.
    def self.project_files
      out, _err, status = Open3.capture3("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
      status.success? ? out.split("\0").uniq.sort : nil
    rescue SystemCallError
      nil
    end

    # A NUL byte in the first 8 KB, as git decides.
    def self.binary?(path)
      File.open(path, "rb") { |file| file.read(8000).to_s.include?("\0") }
    end

    # Files named on the command line, with directories expanded.
    def self.expand_arguments(arguments)
      arguments.flat_map do |argument|
        if File.directory?(argument)
          files([File.join(argument, "**", "*").delete_prefix("./")])
        else
          [argument]
        end
      end.map { |path| path.delete_prefix("./") }.uniq
    end
  end
end
