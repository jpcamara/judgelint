# frozen_string_literal: true

module Judgelint
  # One rule's outcome for one file.
  #
  # +status+ is :violation (at or above the rule's threshold), :uncertain
  # (between warn_at and the threshold), :pass, :skipped (the file is too
  # large to judge), :refused (the model declined the question), or
  # :suppressed (a judgelint:disable comment covers it). Skipped and refused
  # files are reported, never silently passed. +lines+ is the [first, last]
  # range the verdict came from.
  #
  # An example's verdict also knows the answer it should have had: +expected+
  # is :pass or :fail for files under rules/<id>/pass and rules/<id>/fail.
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Verdict
    attr_reader :rule, :path, :probability, :status, :lines, :expected

    def initialize(rule:, path:, probability:, status:, lines: nil, expected: nil)
      @rule = rule
      @path = path
      @probability = probability
      @status = status
      @lines = lines
      @expected = expected
    end

    def as_example(expected)
      Verdict.new(rule: rule, path: path, probability: probability, status: status, lines: lines, expected: expected)
    end

    # +probability+ is the probability the code breaks the rule.
    def self.classify(rule, path, probability, warn_at:, lines: nil)
      status =
        if probability >= rule.threshold then :violation
        elsif probability >= warn_at then :uncertain
        else :pass
        end
      new(rule: rule, path: path, probability: probability, status: status, lines: lines)
    end

    def failing?
      status == :violation && rule.error?
    end

    # A refused, skipped, or suppressed example is a miss either way: the rule
    # didn't work on it.
    def correct?
      return false if %i[refused skipped suppressed].include?(status)

      (status == :violation) == (expected == :fail)
    end

    def to_h
      {
        "path" => path, "lines" => lines, "rule" => rule.id, "severity" => rule.severity, "status" => status.to_s,
        "probability" => probability&.round(3), "message" => rule.message
      }.merge(expected ? { "expected" => expected.to_s, "correct" => correct? } : {})
    end
  end
end
