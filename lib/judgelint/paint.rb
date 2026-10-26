# frozen_string_literal: true

module Judgelint
  # Colors for a terminal. They're on when the stream is a terminal, unless
  # NO_COLOR is set or TERM is dumb. FORCE_COLOR turns them on anywhere, so
  # piped output can be colored too. With colors off, text passes through
  # unchanged.
  class Paint
    BOLD = "1"
    DIM = "2"
    RED = "31"
    GREEN = "32"
    YELLOW = "33"
    CYAN = "36"
    BOLD_RED = "1;31"
    BOLD_GREEN = "1;32"

    def self.for(io)
      new(color?(io))
    end

    def self.color?(io)
      return false if set?("NO_COLOR") || ENV.fetch("TERM", "") == "dumb"
      return true if set?("FORCE_COLOR") && ENV.fetch("FORCE_COLOR", "") != "0"

      io.tty?
    end

    def self.set?(name)
      !ENV.fetch(name, "").empty?
    end

    def initialize(on)
      @on = on
    end

    def on?
      @on
    end

    # +text+ in the SGR style +code+, such as Paint::RED.
    def call(text, code)
      @on ? "\e[#{code}m#{text}\e[0m" : text
    end
  end
end
