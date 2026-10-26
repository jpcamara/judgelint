# frozen_string_literal: true

module Judgelint
  # Prints results as text, JSON, GitHub Actions annotations, or SARIF. Data
  # goes to stdout; anything else goes to stderr.
  class Reporter
    FORMATS = %w[text json github sarif].freeze
    MARKS = { violation: "x", uncertain: "?", skipped: "-", refused: "-", excused: "-" }.freeze
    # In color, a violation's mark is a cross.
    COLOR_MARKS = { violation: "\u2717", uncertain: "?", skipped: "-", refused: "-", excused: "-" }.freeze
    STATUSES = %w[violation uncertain pass skipped refused excused].freeze

    # +paint+ colors the text format; the others are never colored.
    def initialize(out, format:, paint: Paint.new(false))
      @out = out
      @format = format
      @paint = paint
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
        tally = @paint.call("#{correct}/#{group.size}", correct == group.size ? Paint::GREEN : Paint::RED)
        @out.puts "#{@paint.call(rule.id, Paint::BOLD)}  #{tally}"
        group.each do |example|
          mark = example.correct? ? cell("ok", 4, Paint::GREEN) : @paint.call("MISS", Paint::BOLD_RED)
          @out.puts "  #{mark} #{cell(example.expected.to_s, 4, Paint::DIM)} " \
                    "#{probability(example)}  #{@paint.call(example.path, Paint::CYAN)}"
        end
      end
      @out.puts "" unless examples.empty?
      correct = examples.count(&:correct?)
      @out.puts @paint.call("#{correct}/#{examples.size} examples judged correctly",
                            correct == examples.size ? Paint::BOLD_GREEN : Paint::BOLD_RED)
    end

    private

    def json(data)
      @out.puts JSON.pretty_generate(data)
    end

    def text(verdicts, file_count)
      shown = verdicts.reject { |verdict| verdict.status == :pass }
      width = shown.map { |verdict| verdict.rule.id.size }.max
      places = [7, *shown.map { |verdict| range(verdict).size }].max
      shown.group_by(&:path).each do |path, group|
        @out.puts @paint.call(path, Paint::BOLD)
        group.each { |verdict| @out.puts "  #{line(verdict, width, places)}" }
      end
      @out.puts "" unless shown.empty?
      @out.puts summary(verdicts, file_count)
    end

    # Columns are padded before they're colored, so they line up either way.
    def line(verdict, width, places)
      label = verdict.status == :violation ? verdict.rule.severity : verdict.status.to_s
      marks = @paint.on? ? COLOR_MARKS : MARKS
      tone = tone(verdict)
      [cell("#{marks.fetch(verdict.status)} #{label}", 12, tone), cell(verdict.rule.id, width, Paint::DIM),
       " #{cell(range(verdict), places, Paint::CYAN)}", "#{@paint.call(probability(verdict), tone)} ",
       verdict.rule.message].join(" ")
    end

    # +text+ in color, padded to +width+ outside it.
    def cell(text, width, code)
      "#{@paint.call(text, code)}#{' ' * [width - text.size, 0].max}"
    end

    # Errors are red, warnings and uncertain findings yellow, the rest dim.
    def tone(verdict)
      return Paint::YELLOW if verdict.status == :uncertain
      return Paint::DIM unless verdict.status == :violation

      verdict.rule.error? ? Paint::BOLD_RED : Paint::YELLOW
    end

    # The line that breaks the rule, or the range asked about; for a
    # directory, the file in it.
    def range(verdict)
      return verdict.file.delete_prefix("#{verdict.path}/") if verdict.file
      return verdict.line.to_s if verdict.line

      verdict.lines ? verdict.lines.join("-") : ""
    end

    def probability(verdict)
      return "  - " if verdict.probability.nil?

      format("%.2f", verdict.probability)
    end

    def summary(verdicts, file_count)
      counts = verdicts.group_by(&:status).transform_values(&:size)
      violations = counts.fetch(:violation, 0)
      parts = ["#{file_count} #{file_count == 1 ? 'file' : 'files'}",
               @paint.call("#{violations} violations", violations.zero? ? Paint::BOLD_GREEN : Paint::BOLD_RED)]
      parts << @paint.call("#{counts[:uncertain]} uncertain", Paint::YELLOW) if counts[:uncertain]
      parts << @paint.call("#{counts[:skipped]} skipped (too large)", Paint::DIM) if counts[:skipped]
      parts << @paint.call("#{counts[:refused]} refused by the model", Paint::DIM) if counts[:refused]
      parts << @paint.call("#{counts[:excused]} excused by judgehints", Paint::DIM) if counts[:excused]
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

      properties = ["file=#{escape(verdict.file || verdict.path, true)}"]
      if verdict.line
        properties << "line=#{verdict.line}"
      elsif verdict.lines
        properties += ["line=#{verdict.lines[0]}", "endLine=#{verdict.lines[1]}"]
      end
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
      region =
        if verdict.line then { "startLine" => verdict.line }
        elsif verdict.lines then { "startLine" => verdict.lines[0], "endLine" => verdict.lines[1] }
        else {}
        end
      level = verdict.status == :uncertain ? "note" : (verdict.rule.error? ? "error" : "warning")
      {
        "ruleId" => verdict.rule.id, "level" => level,
        "message" => { "text" => "#{verdict.rule.message} (#{probability(verdict)})" },
        "locations" => [{ "physicalLocation" => { "artifactLocation" => { "uri" => verdict.file || verdict.path }, "region" => region } }]
      }
    end
  end
end
