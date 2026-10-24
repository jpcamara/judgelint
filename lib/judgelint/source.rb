# frozen_string_literal: true

module Judgelint
  # What the model is shown: one file, or every file in a directory, with each
  # line numbered so a question can point at a range, followed by any context
  # files the rule names, which are there to read and never judged.
  #
  # A judgehint is a comment (#, //, --, /*, <!--, or ;) starting with
  # `judgehint:` that says why the code is the way it is. The model weighs it
  # for the window it falls in, or for the whole directory.
  class Source
    HINT = %r{(?:#|//|--|/\*|<!--|;)\s*judgehint:}

    attr_reader :path, :shown_as, :line_count

    def self.directory(dir, shown_as: dir, context: [])
      files = Glob.expand([File.join(dir, "**", "*")])
      new(dir, shown_as: shown_as, files: files, context: context, directory: true)
    end

    def initialize(path, shown_as: path, files: [path], context: [], directory: false)
      @path = path
      @shown_as = shown_as
      @directory = directory
      @files = files.map { |file| [file, File.read(file).lines] }
      @context = context
      @line_count = @files.sum { |_file, lines| lines.size }
      @hints = []
      @files.each do |_file, lines|
        lines.each_with_index { |line, index| @hints << index + 1 if HINT.match?(line) }
      end
    end

    def directory?
      @directory
    end

    def state
      body =
        if directory?
          sections = @files.map { |file, lines| "Path: #{shown(file)}\n\n#{numbered(lines)}" }
          "Directory: #{shown_as}\n\n#{sections.join("\n")}"
        else
          "Path: #{shown_as}\n\n#{numbered(@files.first[1])}"
        end
      return body if @context.empty?

      references = @context.map { |file| "Path: #{file}\n\n#{File.read(file)}" }
      "#{body}\nContext, for reference only (not under review):\n\n#{references.join("\n")}"
    end

    # [first, last] ranges of +size+ lines that cover the file.
    def windows(size)
      (1..line_count).step(size).map { |first| [first, [first + size - 1, line_count].min] }
    end

    def hinted?(first, last)
      directory? ? !@hints.empty? : @hints.any? { |line| line.between?(first, last) }
    end

    private

    def numbered(lines)
      lines.each_with_index.map { |line, index| "#{index + 1}: #{line.chomp}\n" }.join
    end

    # A file's path inside the directory, as the model sees it.
    def shown(file)
      "#{shown_as}/#{file.delete_prefix("#{path}/")}"
    end
  end
end
