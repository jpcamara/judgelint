# frozen_string_literal: true

module Judgelint
  # Path matching shared by rule targeting and file discovery. `**/` matches
  # zero or more directories and `{a,b}` alternates, as in Dir.glob.
  module Glob
    FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    def self.match_any?(patterns, path)
      patterns.any? { |pattern| File.fnmatch?(pattern, path, FLAGS) }
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
