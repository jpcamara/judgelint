# frozen_string_literal: true

module Judgelint
  # One rule's outcome for one file.
  #
  # +status+ is :violation (at or above the rule's threshold), :uncertain
  # (between warn_at and the threshold), :pass, :skipped (the file is too
  # large to judge), :refused (the model declined the question), or :excused
  # (a violation or uncertain, but a judgehint excuses it). Skipped and
  # refused files are reported, never silently passed. +lines+ is the [first,
  # last] range the verdict came from. +line+ is the line in it that breaks
  # the rule, and +file+ the file in a directory, when the model could say.
  #
  # An example's verdict also knows the answer it should have had: +expected+
  # is :pass or :fail for files under rules/<id>/pass and rules/<id>/fail.
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Verdict
    attr_reader :rule, :path, :probability, :status, :line, :file, :expected

    # The range is kept as two numbers, since a run holds a verdict for every
    # rule and file.
    def initialize(rule:, path:, probability:, status:, lines: nil, line: nil, file: nil, expected: nil)
      @rule = rule
      @path = path
      @probability = probability
      @status = status
      @first = lines && lines[0]
      @last = lines && lines[1]
      @line = line
      @file = file
      @expected = expected
    end

    def lines
      @first && [@first, @last]
    end

    def as_example(expected)
      Verdict.new(rule: rule, path: path, probability: probability, status: status, lines: lines, line: line, file: file,
                  expected: expected)
    end

    # +probability+ is the probability the code breaks the rule.
    def self.classify(rule, path, probability, warn_at:, lines: nil, line: nil, file: nil)
      status =
        if probability >= rule.threshold then :violation
        elsif probability >= warn_at then :uncertain
        else :pass
        end
      new(rule: rule, path: path, probability: probability, status: status, lines: lines, line: line, file: file)
    end

    def failing?
      status == :violation && rule.error?
    end

    # A refused or skipped example is a miss either way: the rule didn't work
    # on it. An excused one isn't a violation.
    def correct?
      return false if %i[refused skipped].include?(status)

      (status == :violation) == (expected == :fail)
    end

    def to_h
      {
        "path" => path, "lines" => lines, "line" => line, "file" => file, "rule" => rule.id, "severity" => rule.severity, "status" => status.to_s,
        "probability" => probability&.round(3), "message" => rule.message
      }.merge(expected ? { "expected" => expected.to_s, "correct" => correct? } : {})
    end
  end
end
