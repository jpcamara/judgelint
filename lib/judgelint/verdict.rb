# frozen_string_literal: true

module Judgelint
  # One rule's outcome for one file.
  #
  # +status+ is :violation (at or above the rule's threshold), :uncertain
  # (between warn_at and the threshold), :pass, or :skipped (the file is too
  # large to judge; it is reported, never silently passed).
  # Not Data.define: Spinel can't compile a Data or Struct in a program that also uses net/https and json.
  class Verdict
    attr_reader :rule, :path, :probability, :status

    def initialize(rule:, path:, probability:, status:)
      @rule = rule
      @path = path
      @probability = probability
      @status = status
    end

    def self.classify(rule, path, yes_probability, warn_at:)
      probability = rule.violation_probability(yes_probability)
      status =
        if probability >= rule.threshold then :violation
        elsif probability >= warn_at then :uncertain
        else :pass
        end
      new(rule: rule, path: path, probability: probability, status: status)
    end

    def failing?
      status == :violation && rule.error?
    end

    def to_h
      {
        "path" => path, "rule" => rule.id, "severity" => rule.severity, "status" => status.to_s,
        "probability" => probability&.round(3), "message" => rule.message
      }
    end
  end
end
