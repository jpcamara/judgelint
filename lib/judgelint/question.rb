# frozen_string_literal: true

module Judgelint
  # One rule asked about one range of a file. The model sees the whole file;
  # the question points at the lines. When a change touched only some of a
  # window's lines, it points at those, so code the change didn't touch can't
  # fail it.
  #
  # A spec's bullet is a choice between breaking the rule, following it, and
  # the rule not applying. With the three side by side, a decision model
  # commits to an answer, where a yes/no question gets a hedge. The same
  # request asks which line (or, for a directory, which file) breaks the rule
  # most clearly, so a finding can name it.
  #
  # A rule written as a question is asked yes or no, as written. Code with a
  # judgehint comment is also asked, yes or no, whether the hint excuses it.
  class Question
    BREAKS = "The code clearly breaks the rule."
    FOLLOWS = "The code follows the rule."
    NOT_APPLICABLE = "The rule doesn't apply to this code."
    EXCUSED = "A judgehint comment is about this rule, and gives a reason the code may break it."
    NOT_EXCUSED = "No judgehint comment is about this rule. Any judgehint is about a different rule, or gives no reason."

    attr_reader :rule, :first, :last, :places, :lines

    # +kind+ is :verdict, :where, or :excuse. +places+ are a :where question's
    # options: line ids (L12) or the directory's files, as the model sees them.
    # +lines+ are the changed lines in the range, or nil to ask about all of it.
    def initialize(rule, first, last, kind: :verdict, places: [], lines: nil)
      @rule = rule
      @first = first
      @last = last
      @kind = kind
      @places = places
      @lines = lines
    end

    def excuse?
      @kind == :excuse
    end

    def where?
      @kind == :where
    end

    # A spec's bullet and its location are choices; everything else is yes or no.
    def choice?
      where? || (@kind == :verdict && !rule.convention.nil?)
    end

    def key
      base = "#{rule.question_key}.#{first}-#{last}"
      return "#{base}.excused" if excuse?
      return "#{base}.where" if where?

      base
    end

    # A choice's options, as {name => description or nil}.
    def options
      return places.to_h { |place| [place, nil] } if where?

      { "breaks" => rule.yes_means || BREAKS, "follows" => rule.no_means || FOLLOWS, "not_applicable" => NOT_APPLICABLE }
    end

    # The probability the code breaks the rule, from a verdict's answer: a
    # choice's probabilities, or a yes/no question's probability of yes.
    def violation(answer)
      return answer["breaks"].to_f if answer.is_a?(Hash)

      rule.violation_probability(answer)
    end

    # "Answer yes only when..." keeps the model from flagging code the rule
    # doesn't cover.
    def instructions
      return excuse_instructions if excuse?
      return where_instructions if where?
      return "How #{rule.scope == 'file' || lines&.size == 1 ? 'does' : 'do'} #{subject} relate to the following team rule? Rule: #{rule.convention}" if rule.convention

      text = rule.window? ? "Look at #{span} of the file; the rest is context. #{rule.question}" : rule.question
      return text unless rule.fail_when == "yes"

      scope = { "window" => "those lines do it", "file" => "the code does it", "directory" => "the files do it" }
              .fetch(rule.scope)
      "#{text} Answer yes only when #{scope}, not when the question doesn't apply."
    end

    def yes_means
      return EXCUSED if excuse?
      return nil if choice?

      rule.yes_means
    end

    def no_means
      return NOT_EXCUSED if excuse?
      return nil if choice?

      rule.no_means
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(JSON.generate([instructions, yes_means.to_s, no_means.to_s,
                                                          choice? ? options.to_a : []]))
    end

    private

    def subject
      { "window" => "#{span} of the file", "file" => "the file", "directory" => "the files" }.fetch(rule.scope)
    end

    # The lines asked about: "lines 41-80", or the changed ones, as "line 7" or
    # "lines 3, 7-9".
    def span
      return "lines #{first}-#{last}" if lines.nil?
      return "line #{lines.first}" if lines.size == 1

      runs = []
      lines.each do |line|
        if !runs.empty? && runs.last[1] == line - 1
          runs.last[1] = line
        else
          runs << [line, line]
        end
      end
      "lines #{runs.map { |run| run[0] == run[1] ? run[0].to_s : "#{run[0]}-#{run[1]}" }.join(', ')}"
    end

    def where_instructions
      which = rule.directory? ? "Which file" : "Which line, given by its number as L<number>,"
      "#{which} most clearly breaks the following team rule? Rule: #{rule.convention}"
    end

    def excuse_instructions
      where = { "window" => "in lines #{first}-#{last} of the file", "file" => "in the file", "directory" => "in the files" }
              .fetch(rule.scope)
      "Does a judgehint comment #{where} explain why the code intentionally departs from the following team " \
        "rule, with a reason specific to this rule? Rule: #{rule.convention || rule.message}"
    end
  end
end
