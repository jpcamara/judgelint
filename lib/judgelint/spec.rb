# frozen_string_literal: true

module Judgelint
  # Finds rules where a team already writes its conventions: a README (or any
  # *.judgelint.md) whose frontmatter says which files it governs, with one
  # convention per top-level bullet, as praxis reads them.
  #
  #   ---
  #   paths: ["src/services/*.ts"]
  #   excludes: ["src/services/legacy-import.ts"]
  #   ---
  #   # Service conventions
  #
  #   - **Domain failures are values, never exceptions.** A service returns
  #     { ok: false, error } for anything a caller could plausibly cause.
  #   - **No I/O except through the injected Store.** No timers, no fetch.
  #
  # Each bullet becomes a rule, with an id from its lead words, such as
  # src/services/domain-failures-are-values-never-exceptions. The model sees
  # the spec's prose alongside the file, and is asked whether the code breaks
  # the bullet and whether it follows it. Indented `violation:` and
  # `compliant:` lines under a bullet say what each looks like:
  #
  #   - **No I/O except through the injected Store.**
  #     violation: calls fetch, console, or a timer directly
  #     compliant: reads and writes only through the Store it's given
  #
  # Files in .judgelint/rules/ work the same way, and one there with a
  # question: in its frontmatter is a single rule asked exactly that way.
  module Spec
    PATTERNS = ["**/README.md", "**/*.judgelint.md"].freeze
    KEYS = %w[paths excludes context scope cohort type severity threshold].freeze
    COHORTS = { "by_file" => "file", "by_directory" => "directory" }.freeze
    BULLET = /\A(?:[-*+]|\d+[.)])\s+(\S.*)\z/
    CRITERION = /\A(violation|compliant):\s*(\S.*)\z/i
    LEAD = /\A\*\*(.+?)\*\*/

    # +readmes+ false looks in +rules_dir+ alone.
    def self.discover(rules_dir:, default_threshold:, ignore: [], readmes: true)
      # path.dup: Spinel can't yet share these Strings into the rules it builds.
      found = Dir.glob(File.join(rules_dir, "*.md")).sort.flat_map do |path|
        load(path.dup, default_threshold: default_threshold, required: true)
      end
      specs = readmes ? Glob.expand(PATTERNS) : []
      specs = specs.reject { |path| path.start_with?("#{rules_dir}/") || Glob.match_any?(ignore, path) }
      found += specs.flat_map { |path| load(path.dup, default_threshold: default_threshold, required: false) }
      raise ConfigError, "No rules: add a README with paths: frontmatter, or run `judgelint init`" if found.empty?

      found.group_by(&:question_key).each_value do |same|
        raise ConfigError, "Rule ids collide: #{same.map(&:id).join(', ')}" if same.size > 1
      end
      found
    end

    # A README without frontmatter, or without paths:, isn't a spec.
    def self.load(path, default_threshold:, required:)
      match = Rule::FRONTMATTER.match(File.read(path))
      unless match
        raise ConfigError, "#{path}: rules start with a --- frontmatter block" if required

        return []
      end

      data = Judgelint.parse_yaml(match[1], path)
      body = match[2]
      return [Rule.new(data, source: path, body: body.strip, default_threshold: default_threshold)] if data.key?("question")
      return [] unless required || data.key?("paths")

      unknown = data.keys - KEYS
      raise ConfigError, "#{path}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

      shared = shared_settings(path, data)
      found = bullets(body)
      raise ConfigError, "#{path}: a rule needs a question, or bullets to turn into rules" if found.empty? && required

      prose = body.strip
      ids = []
      found.map do |text, criteria|
        id = unique("#{name(path)}/#{slug(text)}", ids)
        rule = shared.merge("id" => id, "convention" => plain(text), "message" => lead(text))
        rule["yes_means"] = plain(criteria["violation"]) if criteria["violation"]
        rule["no_means"] = plain(criteria["compliant"]) if criteria["compliant"]
        rule["severity"] = severity(text) unless data.key?("severity")
        Rule.new(rule, source: path, default_threshold: default_threshold, prose: prose,
                       examples_dir: File.join(".judgelint", "examples", id))
      end
    end

    def self.shared_settings(path, data)
      settings = {}
      %w[paths excludes context severity threshold].each { |key| settings[key] = data[key] if data.key?(key) }
      if data.key?("cohort")
        cohort = data["cohort"].to_s
        raise ConfigError, "#{path}: cohort is by_file or by_directory, not #{cohort}" unless COHORTS.key?(cohort)

        settings["scope"] = COHORTS.fetch(cohort)
      end
      settings["scope"] = data["scope"] if data.key?("scope")
      settings
    end

    # The top-level bullets of the body, outside code fences, as [text,
    # criteria]: the text with its continuation lines and nested bullets, and
    # any indented violation: or compliant: lines.
    def self.bullets(body)
      found = []
      current = nil
      criteria = {}
      criterion = nil
      fenced = false
      body.each_line do |raw|
        line = raw.chomp
        if line.lstrip.start_with?("```")
          fenced = !fenced
          next
        end
        next if fenced

        bullet = BULLET.match(line)
        if bullet
          found << [current, criteria] if current
          current = bullet[1]
          criteria = {}
          criterion = nil
        elsif current && line.start_with?(" ", "\t") && !line.strip.empty?
          nested = BULLET.match(line.strip)
          text = nested ? nested[1] : line.strip
          named = CRITERION.match(text)
          if named
            criterion = named[1].downcase
            criteria[criterion] = named[2]
          elsif criterion
            criteria[criterion] = "#{criteria[criterion]} #{text}"
          else
            current = "#{current} #{text}"
          end
        elsif current && !line.strip.empty?
          found << [current, criteria]
          current = nil
        end
      end
      found << [current, criteria] if current
      found
    end

    # The bullet with its markdown emphasis removed: what the model is asked about.
    def self.plain(text)
      text.gsub("**", "").gsub(/\s+/, " ").strip
    end

    # The bold lead, or the first sentence: what judgelint prints for a finding.
    def self.lead(text)
      bold = LEAD.match(text)
      sentence = bold ? bold[1] : plain(text)
      sentence = sentence[0, sentence.index(/[.!?:](\s|\z)/) || sentence.size]
      "#{sentence.strip.sub(/[.!?:]\z/, '')}."
    end

    def self.slug(text)
      words = lead(text).downcase.scan(/[a-z0-9]+/).first(6)
      words.empty? ? "rule" : words.join("-")
    end

    def self.unique(id, taken)
      candidate = id
      number = 1
      while taken.include?(candidate)
        number += 1
        candidate = "#{id}-#{number}"
      end
      taken << candidate
      candidate
    end

    # Spec names: a README's directory, a *.judgelint.md's stem, or a rules file's name.
    def self.name(path)
      dir = File.dirname(path)
      return(dir == "." ? "root" : dir) if File.basename(path) == "README.md"

      File.basename(path).delete_suffix(".md").delete_suffix(".judgelint")
    end

    # Praxis's reading: "should" and "prefer" are advice, anything else is a rule.
    def self.severity(text)
      advisory = /\b(should|prefer|ideally|consider)\b/i.match?(text)
      advisory && !/\b(must|never|always)\b/i.match?(text) ? "warning" : "error"
    end
  end
end
