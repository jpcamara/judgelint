# frozen_string_literal: true

module Judgelint
  # A file as the model sees it: its path and every line, numbered, so a
  # question can point at a range while the model reads the whole file.
  #
  # Inline suppressions turn a rule off where a person has decided the code is
  # fine, and say why: a comment (#, //, --, /*, <!--, or ;) starting with
  # `judgelint:disable <rule ids> -- <reason>` covers the window it falls in,
  # and `judgelint:disable-file <rule ids> -- <reason>` covers the whole file.
  class Source
    SUPPRESSION = %r{(?:#|//|--|/\*|<!--|;)\s*judgelint:(disable-file|disable)\b(.*)\z}
    REASONED = /\A\s+([A-Za-z0-9_, -]+?)\s+--\s+\S/

    attr_reader :path, :shown_as, :line_count

    def initialize(path, shown_as: path)
      @path = path
      @shown_as = shown_as
      @lines = File.read(path).lines
      @line_count = @lines.size
      @disabled = {}
      @disabled_file = []
      find_suppressions
    end

    def state
      numbered = @lines.each_with_index.map { |line, index| "#{index + 1}: #{line.chomp}\n" }
      "Path: #{shown_as}\n\n#{numbered.join}"
    end

    # [first, last] ranges of +size+ lines that cover the file.
    def windows(size)
      (1..line_count).step(size).map { |first| [first, [first + size - 1, line_count].min] }
    end

    def suppressed?(rule_id, first, last)
      return true if @disabled_file.include?(rule_id)

      (@disabled[rule_id] || []).any? { |line| line.between?(first, last) }
    end

    def suppressed_ids
      (@disabled.keys + @disabled_file).uniq
    end

    private

    def find_suppressions
      @lines.each_with_index do |line, index|
        match = SUPPRESSION.match(line.chomp)
        next unless match

        reasoned = REASONED.match(match[2])
        raise ConfigError, "#{path}:#{index + 1}: judgelint:#{match[1]} needs rule ids and a reason after --" unless reasoned

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
