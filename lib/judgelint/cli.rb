# frozen_string_literal: true

module Judgelint
  # Command line entry point. Exit codes: 0 clean, 1 violations (or missed
  # examples for `test`), 2 usage or configuration error.
  class CLI
    COMMANDS = %w[check test rules init].freeze

    HELP = <<~TEXT
      Usage: judgelint [command] [options] [paths...]

      Lints files against conventions a regular linter can't check. Each rule is a
      yes/no question answered by a System One decision model (Jev by default).

      Commands:
        check [paths...]   Judge files against the rules that govern them (default).
                           With no paths, checks every file the rules' globs match.
        test [rule ids...] Judge each rule's examples (rules/<id>/pass, rules/<id>/fail)
                           and report how many the model gets right.
        rules              List rules and how many files each one governs.
        init               Write .judgelint.yml and an example rule.

      Options:
        -c, --config PATH    Config file (default .judgelint.yml)
        -f, --format FORMAT  text or json
            --provider NAME  typesafe, celeris, or openrouter
            --model ID       Decision model id
            --threshold N    Violation probability that counts as a violation (default 0.7)
            --no-cache       Ask the model even when an answer is cached
        -v, --version        Print the version
        -h, --help           Print this help

      Exit status: 0 clean, 1 violations or missed examples, 2 usage or config error.
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @options = { "format" => "text", "config" => nil }
      @overrides = {}
    end

    def run
      command = COMMANDS.include?(@argv.first) ? @argv.shift : "check"
      @argv = parse_options(@argv)
      return 0 if @options["done"]

      case command
      when "check" then check
      when "test" then test
      when "rules" then list_rules
      when "init" then init
      end
    rescue UsageError => e
      @err.puts "judgelint: #{e.message}"
      @err.puts "Run `judgelint --help` for usage."
      2
    rescue Error => e
      @err.puts "judgelint: #{e.message}"
      2
    end

    private

    # Spinel can't compile OptionParser, so the few options are parsed here.
    VALUE_OPTIONS = {
      "-c" => "config", "--config" => "config", "-f" => "format", "--format" => "format",
      "--provider" => "provider", "--model" => "model", "--threshold" => "threshold"
    }.freeze
    FORMATS = %w[text json].freeze

    def parse_options(argv)
      rest = []
      until argv.empty?
        arg = argv.shift
        name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        if arg == "--"
          rest.concat(argv)
          argv = []
        elsif VALUE_OPTIONS.key?(name)
          value = inline || argv.shift
          raise UsageError, "#{name} needs a value" if value.nil?

          set_option(VALUE_OPTIONS.fetch(name), value)
        elsif arg == "--no-cache"
          @overrides["cache"] = false
        elsif arg == "-v" || arg == "--version"
          @out.puts "judgelint #{VERSION}"
          @options["done"] = true
        elsif arg == "-h" || arg == "--help"
          @out.puts HELP
          @options["done"] = true
        elsif arg.start_with?("-") && arg != "-"
          raise UsageError, "unknown option #{arg}"
        else
          rest << arg
        end
      end
      rest
    end

    def set_option(key, value)
      case key
      when "config" then @options["config"] = value
      when "format"
        raise UsageError, "--format is text or json, not #{value}" unless FORMATS.include?(value)

        @options["format"] = value
      else @overrides[key] = value
      end
    end

    def check
      config, rules = load_rules
      paths = @argv.empty? ? Glob.expand(rules.flat_map(&:paths)) : Glob.expand_arguments(@argv)
      missing = paths.reject { |path| File.file?(path) }
      raise ConfigError, "No such file: #{missing.join(', ')}" unless missing.empty?

      paths = paths.select { |path| rules.any? { |rule| rule.applies_to?(path) } }
      verdicts = runner(config, rules).run(paths)
      Reporter.new(@out, format: @options["format"]).check(verdicts, config: config, file_count: paths.size)
      verdicts.any?(&:failing?) ? 1 : 0
    end

    def test
      config, rules = load_rules
      unless @argv.empty?
        unknown = @argv - rules.map(&:id)
        raise ConfigError, "Unknown rules: #{unknown.join(', ')}" unless unknown.empty?

        rules = rules.select { |rule| @argv.include?(rule.id) }
      end

      cache = Cache.new(config.cache_path)
      runner = Runner.new(config: config, rules: rules, client: Client.new(config), cache: cache)
      examples = FixtureRunner.new(runner).run(rules)
      cache.save
      if examples.empty?
        @err.puts "No examples found. Add files under <rules>/<id>/pass and <rules>/<id>/fail."
        return 0
      end

      Reporter.new(@out, format: @options["format"]).fixtures(examples)
      examples.all?(&:correct?) ? 0 : 1
    end

    def list_rules
      _config, rules = load_rules
      rules.each do |rule|
        count = Glob.expand(rule.paths).count { |path| rule.applies_to?(path) }
        @out.puts format("%-24s %-8s %5d files  %s", rule.id, rule.severity, count, rule.question)
      end
      0
    end

    def init
      Scaffold.write(".", @out)
      @err.puts "Next: set TYPESAFE_API_KEY, then run `judgelint test` to see the example rule judged."
      0
    end

    def load_rules
      config = ConfigLoader.load(path: @options["config"], overrides: @overrides)
      [config, RuleLoader.load_dir(config.rules_dir, default_threshold: config.threshold)]
    end

    def runner(config, rules)
      Runner.new(config: config, rules: rules, client: Client.new(config), cache: Cache.new(config.cache_path))
    end
  end
end
