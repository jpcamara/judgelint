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
      patterns.flat_map { |pattern| Dir.glob(pattern) }.select { |path| File.file?(path) }.uniq.sort
    end

    # Files named on the command line, with directories expanded.
    def self.expand_arguments(arguments)
      arguments.flat_map do |argument|
        if File.directory?(argument)
          expand([File.join(argument, "**", "*")])
        else
          [argument]
        end
      end.map { |path| path.delete_prefix("./") }.uniq
    end
  end
end
