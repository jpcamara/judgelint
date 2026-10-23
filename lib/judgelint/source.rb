# frozen_string_literal: true

module Judgelint
  # What the model is shown: one file, or every file in a directory, with each
  # line numbered so a question can point at a range, followed by any context
  # files the rule names, which are there to read and never judged.
  #
  # Inline suppressions turn a rule off where a person has decided the code is
  # fine, and say why: a comment (#, //, --, /*, <!--, or ;) starting with
  # `judgelint:disable <rule ids> -- <reason>` covers the window it falls in,
  # and `judgelint:disable-file <rule ids> -- <reason>` covers the whole file.
  # In a directory, either one covers the directory.
  class Source
    SUPPRESSION = %r{(?:#|//|--|/\*|<!--|;)\s*judgelint:(disable-file|disable)\b(.*)\z}
    REASONED = /\A\s+([A-Za-z0-9_, -]+?)\s+--\s+\S/

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
      @disabled = {}
      @disabled_file = []
      @files.each { |file, lines| find_suppressions(file, lines) }
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

    def suppressed?(rule_id, first, last)
      return true if @disabled_file.include?(rule_id)

      lines = @disabled[rule_id] || []
      directory? ? !lines.empty? : lines.any? { |line| line.between?(first, last) }
    end

    def suppressed_ids
      (@disabled.keys + @disabled_file).uniq
    end

    private

    def numbered(lines)
      lines.each_with_index.map { |line, index| "#{index + 1}: #{line.chomp}\n" }.join
    end

    # A file's path inside the directory, as the model sees it.
    def shown(file)
      "#{shown_as}/#{file.delete_prefix("#{path}/")}"
    end

    def find_suppressions(file, lines)
      lines.each_with_index do |line, index|
        match = SUPPRESSION.match(line.chomp)
        next unless match

        reasoned = REASONED.match(match[2])
        raise ConfigError, "#{file}:#{index + 1}: judgelint:#{match[1]} needs rule ids and a reason after --" unless reasoned

        ids = reasoned[1].split(/[\s,]+/).reject(&:empty?)
        if match[1] == "disable-file"
          @disabled_file.concat(ids)
        else
          ids.each { |id| (@disabled[id] ||= []) << index + 1 }
        end
      end
    end
  end
end
