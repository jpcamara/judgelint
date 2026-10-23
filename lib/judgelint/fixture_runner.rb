# frozen_string_literal: true

module Judgelint
  # Runs each rule against its examples: files under rules/<id>/pass must not
  # be judged violations, files under rules/<id>/fail must. Decision models are
  # much better at classifying than at applying a policy, so a rule earns its
  # place by passing its own examples.
  class FixtureRunner
    # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
    class Example
      attr_reader :rule, :path, :expected, :verdict

      def initialize(rule:, path:, expected:, verdict:)
        @rule = rule
        @path = path
        @expected = expected
        @verdict = verdict
      end

      def correct?
        (verdict.status == :violation) == (expected == :fail)
      end
    end

    def initialize(runner)
      @runner = runner
    end

    def run(rules)
      rules.flat_map do |rule|
        %i[pass fail].flat_map do |expected|
          dir = File.join(rule.examples_dir, expected.to_s)
          Glob.expand([File.join(dir, "**", "*")]).map do |path|
            verdict = @runner.judge_file(path, [rule], shown_as: path.delete_prefix("#{dir}/")).first
            Example.new(rule: rule, path: path, expected: expected, verdict: verdict)
          end
        end
      end
    end
  end
end
