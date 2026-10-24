# frozen_string_literal: true

module Judgelint
  # Command line entry point. Exit codes: 0 clean, 1 violations (or missed
  # examples for `test`), 2 usage or configuration error. Everything that can
  # be checked is checked before the first paid request.
  class CLI
    COMMANDS = %w[check test rules providers init].freeze

    HELP = <<~TEXT
      Usage: judgelint [command] [options] [paths...]

      Checks code against the conventions in your specs. For each file and each
      rule, it asks a decision model (Jev by default) whether the code breaks it.

      Commands:
        check [paths...]   Check the files the specs govern, or these (default).
        test [rule ids...] Judge each rule's examples (.judgelint/examples/<id>/pass
                           and fail) and report what the model gets wrong.
        rules              List the rules and how many files each governs.
        providers          List the decision-model providers judgelint knows.
        init               Write .judgelint.yml and an example spec.

      Options:
            --base REF       Check only what changed since the merge base with REF,
                             uncommitted work included
            --pr             --base the pull request's base branch, from CI variables
                             or the gh CLI
        -f, --format FORMAT  text, json, github (Actions annotations), or sarif
        -m, --model MODEL    Ask this model instead of the config's: a provider from
                             `judgelint providers`, optionally :model (cloudflare:clef)
        -c, --config PATH    Config file (default .judgelint.yml)
            --no-cache       Ask the models even when an answer is cached
        -y, --yes            Run even past max_cost_usd
        -v, --version        Print the version
        -h, --help           Print this help

      Exit status: 0 clean, 1 violations or missed examples, 2 usage or config error.
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @format = "text"
      @config_path = nil
      @base = nil
      @pr = false
      @yes = false
      @overrides = {}
      @usage = nil
      @no_cache = false
    end

    def run
      command = COMMANDS.include?(@argv.first) ? @argv.shift : "check"
      @argv = parse_options(@argv)
      return 0 if @done

      case command
      when "check" then check
      when "test" then test
      when "rules" then list_rules
      when "providers" then list_providers
      when "init" then init
      end
    rescue UsageError => e
      @err.puts "judgelint: #{e.message}"
      @err.puts "Run `judgelint --help` for usage."
      2
    rescue Error => e
      @err.puts "judgelint: #{e.message}"
      # Requests that succeeded before the failure are still billed.
      @err.puts @usage.line if @usage && @usage.requests.positive?
      2
    end

    private

    # Spinel can't compile OptionParser, so the few options are parsed here.
    VALUE_OPTIONS = {
      "-c" => "config", "--config" => "config", "-f" => "format", "--format" => "format", "--base" => "base",
      "-m" => "models", "--model" => "models"
    }.freeze

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
          @no_cache = true
        elsif arg == "--pr"
          @pr = true
        elsif %w[-y --yes].include?(arg)
          @yes = true
        elsif %w[-v --version -h --help].include?(arg)
          @out.puts(%w[-v --version].include?(arg) ? "judgelint #{VERSION}" : HELP)
          @done = true
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
      when "config" then @config_path = value
      when "base" then @base = value
      when "format"
        raise UsageError, "--format is #{Reporter::FORMATS.join(', ')}, not #{value}" unless Reporter::FORMATS.include?(value)

        @format = value
      else @overrides[key] = value
      end
    end

    def check
      config, rules = load_rules
      raise UsageError, "--base and --pr don't go together" if @base && @pr

      base = @pr ? Changes.pr_base : @base
      changes = base ? Changes.since(base) : nil
      paths = check_paths(rules, changes).reject { |path| Glob.match_any?(config.ignore, path) }
      directories = check_directories(rules).reject { |dir| Glob.match_any?(config.ignore, dir) }
      units = paths.size + directories.size
      runner = runner(config, rules)
      jobs = runner.plan(paths, directories: directories, changes: changes)
      guard_cost(config, runner, jobs)
      verdicts = runner.execute(jobs).flatten
      Reporter.new(@out, format: @format).check(verdicts, config: config, file_count: units, usage: @usage)
      @err.puts @usage.line
      verdicts.any?(&:failing?) ? 1 : 0
    end

    def check_paths(rules, changes)
      if !@argv.empty?
        paths = Glob.expand_arguments(@argv)
        missing = paths.reject { |path| File.file?(path) }
        raise ConfigError, "No such file: #{missing.join(', ')}" unless missing.empty?

        paths = paths.select { |path| changes.key?(path) } if changes
      elsif changes
        paths = changes.keys.sort.select { |path| File.file?(path) }
      else
        paths = Glob.expand(rules.flat_map(&:paths))
      end
      paths.select { |path| rules.any? { |rule| !rule.directory? && rule.applies_to?(path) } }
    end

    # The directories directory rules govern; with paths named, those the
    # paths are in or are. With a change, the runner keeps those it touched.
    def check_directories(rules)
      directories = rules.select(&:directory?).flat_map(&:directories).uniq.sort
      return directories if @argv.empty?

      named = @argv.map { |arg| arg.delete_prefix("./").delete_suffix("/") }
      directories.select { |dir| named.any? { |path| path == dir || path.start_with?("#{dir}/") || dir.start_with?("#{path}/") } }
    end

    def test
      config, rules = load_rules
      unless @argv.empty?
        unknown = @argv - rules.map(&:id)
        raise ConfigError, "Unknown rules: #{unknown.join(', ')}" unless unknown.empty?

        rules = rules.select { |rule| @argv.include?(rule.id) }
      end

      runner = runner(config, rules)
      jobs = runner.plan_examples
      untested = runner.untested
      raise ConfigError, "No rule has examples yet. Add some under #{rules.first.examples_dir}/{pass,fail}/" if jobs.empty?

      @err.puts "#{untested.size} #{untested.size == 1 ? 'rule has' : 'rules have'} no examples: #{untested.map(&:id).join(', ')}" unless untested.empty?
      guard_cost(config, runner, jobs)
      examples = runner.execute(jobs).flatten
      Reporter.new(@out, format: @format).fixtures(examples, usage: @usage)
      @err.puts @usage.line
      examples.all?(&:correct?) ? 0 : 1
    end

    # Prices the planned requests and refuses a run over max_cost_usd.
    def guard_cost(config, runner, jobs)
      estimate = runner.estimated_cost(jobs)
      return if estimate.nil? || estimate <= config.max_cost_usd || @yes

      raise ConfigError, format("This run would send %d requests, about %s input tokens ($%.2f), over max_cost_usd " \
                                "($%.2f). Pass --yes to run it anyway.", runner.request_count(jobs),
                                Usage.delimit(runner.estimated_tokens(jobs)), estimate, config.max_cost_usd)
    end

    def list_rules
      _config, rules = load_rules
      rules.each do |rule|
        count = rule.directory? ? "#{rule.directories.size} dirs" : "#{Glob.expand(rule.paths).count { |path| rule.applies_to?(path) }} files"
        @out.puts format("%-24s %-8s %10s  %s", rule.id, rule.severity, count, rule.question || rule.message)
      end
      0
    end

    def list_providers
      PROVIDERS.each do |name, preset|
        model = preset["model"] || "(you choose)"
        key = preset["api_key_env"] || "no key"
        @out.puts format("%-13s %-28s %-22s %s", name, model, key, preset["api_base"] || "(your endpoint)")
        @out.puts "              needs #{preset['needs']}" if preset["needs"]
      end
      0
    end

    def init
      Scaffold.write(".", @out)
      @err.puts "Next: set TYPESAFE_API_KEY, then run `judgelint test` to see the example rule judged."
      0
    end

    def load_rules
      config = Config.load(path: @config_path, overrides: @overrides)
      [config, Spec.discover(rules_dir: Config::RULES_DIR, default_threshold: config.threshold, ignore: config.ignore)]
    end

    def runner(config, rules)
      @usage = Usage.new
      clients = config.models.map { |endpoint| Client.new(endpoint, usage: @usage) }
      Runner.new(config: config, rules: rules, clients: clients, cache: Cache.new(@no_cache ? nil : Config::CACHE))
    end
  end
end
