# frozen_string_literal: true

module Judgelint
  # Prints results. Data goes to stdout; anything else goes to stderr.
  class Reporter
    MARKS = { violation: "x", uncertain: "?", skipped: "-", refused: "-" }.freeze

    def initialize(out, format:)
      @out = out
      @format = format
    end

    def check(verdicts, config:, file_count:)
      return @out.puts(JSON.pretty_generate(check_json(verdicts, config, file_count))) if @format == "json"

      shown = verdicts.reject { |verdict| verdict.status == :pass }
      shown.group_by(&:path).each do |path, group|
        @out.puts path
        group.each { |verdict| @out.puts "  #{line(verdict)}" }
      end
      @out.puts "" unless shown.empty?
      @out.puts summary(verdicts, file_count)
    end

    def fixtures(examples)
      return @out.puts(JSON.pretty_generate(fixtures_json(examples))) if @format == "json"

      examples.group_by(&:rule).each do |rule, group|
        correct = group.count(&:correct?)
        @out.puts "#{rule.id}  #{correct}/#{group.size}"
        group.each do |example|
          mark = example.correct? ? "ok" : "MISS"
          @out.puts format("  %-4s %-4s %s  %s", mark, example.expected, probability(example.verdict), example.path)
        end
      end
      correct = examples.count(&:correct?)
      @out.puts "" unless examples.empty?
      @out.puts "#{correct}/#{examples.size} examples judged correctly"
    end

    private

    def line(verdict)
      label = verdict.status == :violation ? verdict.rule.severity : verdict.status.to_s
      format("%s %-9s %-24s %s  %s", MARKS.fetch(verdict.status), label, verdict.rule.id,
             probability(verdict), verdict.rule.message)
    end

    def probability(verdict)
      return "  - " if verdict.probability.nil?

      format("%.2f", verdict.probability)
    end

    def summary(verdicts, file_count)
      counts = verdicts.group_by(&:status).transform_values(&:size)
      parts = ["#{file_count} #{file_count == 1 ? 'file' : 'files'}"]
      parts << "#{counts.fetch(:violation, 0)} violations"
      parts << "#{counts[:uncertain]} uncertain" if counts[:uncertain]
      parts << "#{counts[:skipped]} skipped (too large)" if counts[:skipped]
      parts << "#{counts[:refused]} refused by the model" if counts[:refused]
      parts.join(", ")
    end

    def check_json(verdicts, config, file_count)
      counts = verdicts.group_by(&:status).transform_values(&:size)
      {
        "version" => VERSION,
        "model" => config.model_label,
        "files" => file_count,
        "summary" => %w[violation uncertain pass skipped refused].to_h { |status| [status, counts.fetch(status.to_sym, 0)] },
        "results" => verdicts.map(&:to_h)
      }
    end

    def fixtures_json(examples)
      {
        "version" => VERSION,
        "correct" => examples.count(&:correct?),
        "total" => examples.size,
        "examples" => examples.map do |example|
          example.verdict.to_h.merge("expected" => example.expected.to_s, "correct" => example.correct?)
        end
      }
    end
  end
end
