# frozen_string_literal: true

module Judgelint
  # Prints results as text, JSON, GitHub Actions annotations, or SARIF. Data
  # goes to stdout; anything else goes to stderr.
  class Reporter
    FORMATS = %w[text json github sarif].freeze
    MARKS = { violation: "x", uncertain: "?", skipped: "-", refused: "-", excused: "-" }.freeze
    STATUSES = %w[violation uncertain pass skipped refused excused].freeze

    def initialize(out, format:)
      @out = out
      @format = format
    end

    def check(verdicts, config:, file_count:, usage:)
      case @format
      when "json" then json(check_json(verdicts, config, file_count, usage))
      when "github" then verdicts.each { |verdict| annotate(verdict) }
      when "sarif" then json(sarif(verdicts))
      else text(verdicts, file_count)
      end
    end

    def fixtures(examples, usage:)
      return json(fixtures_json(examples, usage)) if @format == "json"

      examples.group_by(&:rule).each do |rule, group|
        correct = group.count(&:correct?)
        @out.puts "#{rule.id}  #{correct}/#{group.size}"
        group.each do |example|
          mark = example.correct? ? "ok" : "MISS"
          @out.puts format("  %-4s %-4s %s  %s", mark, example.expected, probability(example), example.path)
        end
      end
      @out.puts "" unless examples.empty?
      @out.puts "#{examples.count(&:correct?)}/#{examples.size} examples judged correctly"
    end

    private

    def json(data)
      @out.puts JSON.pretty_generate(data)
    end

    def text(verdicts, file_count)
      shown = verdicts.reject { |verdict| verdict.status == :pass }
      width = shown.map { |verdict| verdict.rule.id.size }.max
      shown.group_by(&:path).each do |path, group|
        @out.puts path
        group.each { |verdict| @out.puts "  #{line(verdict, width)}" }
      end
      @out.puts "" unless shown.empty?
      @out.puts summary(verdicts, file_count)
    end

    def line(verdict, width)
      label = verdict.status == :violation ? verdict.rule.severity : verdict.status.to_s
      format("%s %-10s %-#{width}s  %-7s %s  %s", MARKS.fetch(verdict.status), label, verdict.rule.id,
             range(verdict), probability(verdict), verdict.rule.message)
    end

    def range(verdict)
      verdict.lines ? verdict.lines.join("-") : ""
    end

    def probability(verdict)
      return "  - " if verdict.probability.nil?

      format("%.2f", verdict.probability)
    end

    def summary(verdicts, file_count)
      counts = verdicts.group_by(&:status).transform_values(&:size)
      parts = ["#{file_count} #{file_count == 1 ? 'file' : 'files'}", "#{counts.fetch(:violation, 0)} violations"]
      parts << "#{counts[:uncertain]} uncertain" if counts[:uncertain]
      parts << "#{counts[:skipped]} skipped (too large)" if counts[:skipped]
      parts << "#{counts[:refused]} refused by the model" if counts[:refused]
      parts << "#{counts[:excused]} excused by judgehints" if counts[:excused]
      parts.join(", ")
    end

    def check_json(verdicts, config, file_count, usage)
      counts = verdicts.group_by(&:status).transform_values(&:size)
      {
        "version" => VERSION,
        "models" => config.models.map(&:label),
        "files" => file_count,
        "summary" => STATUSES.to_h { |status| [status, counts.fetch(status.to_sym, 0)] },
        "usage" => usage.to_h,
        "results" => verdicts.map(&:to_h)
      }
    end

    def fixtures_json(examples, usage)
      {
        "version" => VERSION,
        "correct" => examples.count(&:correct?),
        "total" => examples.size,
        "usage" => usage.to_h,
        "examples" => examples.map(&:to_h)
      }
    end

    # GitHub Actions workflow commands, which show up on the pull request's lines.
    def annotate(verdict)
      level = { violation: verdict.rule.error? ? "error" : "warning", uncertain: "notice" }[verdict.status]
      return unless level

      properties = ["file=#{escape(verdict.path, true)}"]
      properties += ["line=#{verdict.lines[0]}", "endLine=#{verdict.lines[1]}"] if verdict.lines
      properties << "title=#{escape("judgelint #{verdict.rule.id}", true)}"
      @out.puts "::#{level} #{properties.join(',')}::#{escape("#{verdict.rule.message} (#{probability(verdict)})", false)}"
    end

    def escape(text, property)
      escaped = text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      property ? escaped.gsub(":", "%3A").gsub(",", "%2C") : escaped
    end

    def sarif(verdicts)
      shown = verdicts.select { |verdict| %i[violation uncertain].include?(verdict.status) }
      rules = shown.map(&:rule).uniq
      {
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => [{
          "tool" => { "driver" => {
            "name" => "judgelint", "version" => VERSION, "informationUri" => "https://github.com/jpcamara/judgelint",
            "rules" => rules.map { |rule| { "id" => rule.id, "shortDescription" => { "text" => rule.message } } }
          } },
          "results" => shown.map { |verdict| sarif_result(verdict) }
        }]
      }
    end

    def sarif_result(verdict)
      region = verdict.lines ? { "startLine" => verdict.lines[0], "endLine" => verdict.lines[1] } : {}
      level = verdict.status == :uncertain ? "note" : (verdict.rule.error? ? "error" : "warning")
      {
        "ruleId" => verdict.rule.id, "level" => level,
        "message" => { "text" => "#{verdict.rule.message} (#{probability(verdict)})" },
        "locations" => [{ "physicalLocation" => { "artifactLocation" => { "uri" => verdict.path }, "region" => region } }]
      }
    end
  end
end
