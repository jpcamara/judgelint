# frozen_string_literal: true

module Judgelint
  # Requests and input tokens across a run, and what they cost. Decision
  # models bill input only, so input tokens are the cost. Shared by every
  # model's client in a run.
  class Usage
    attr_reader :requests, :input_tokens

    def initialize
      @requests = 0
      @input_tokens = 0
      @cost = 0.0
      @unpriced = false
      @lock = Mutex.new
    end

    # OpenRouter reports each request's cost; for the rest it's tokens x the
    # model's price. A request with neither makes the run's cost unknown.
    def record(data, price_per_million)
      usage = data["usage"].is_a?(Hash) ? data["usage"] : {}
      tokens = usage["input_tokens"].to_i
      @lock.synchronize do
        @requests += 1
        @input_tokens += tokens
        if usage["cost"].is_a?(Numeric)
          @cost += usage["cost"].to_f
        elsif price_per_million
          @cost += tokens * price_per_million / 1_000_000.0
        else
          @unpriced = true
        end
      end
    end

    def cost
      @unpriced ? nil : @cost
    end

    def to_h
      { "requests" => requests, "input_tokens" => input_tokens, "cost_usd" => cost&.round(6) }
    end

    def line
      cost_text = cost ? format("$%.4f", cost) : "cost unknown (no price for a model)"
      "judgelint: #{requests} #{requests == 1 ? 'request' : 'requests'}, #{Usage.delimit(input_tokens)} input tokens, #{cost_text}"
    end

    def self.delimit(number)
      number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
