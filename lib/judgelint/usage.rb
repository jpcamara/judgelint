# frozen_string_literal: true

module Judgelint
  # Requests and input tokens across a run, and what they cost. Decision
  # models bill input only, so input tokens are the cost.
  class Usage
    attr_reader :requests, :input_tokens

    def initialize(price_per_million)
      @price = price_per_million
      @requests = 0
      @input_tokens = 0
      @reported_cost = 0.0
      @lock = Mutex.new
    end

    # OpenRouter reports each request's cost; for the rest it's tokens x price.
    def record(data)
      usage = data["usage"].is_a?(Hash) ? data["usage"] : {}
      @lock.synchronize do
        @requests += 1
        @input_tokens += usage["input_tokens"].to_i
        @reported_cost += usage["cost"].to_f if usage["cost"].is_a?(Numeric)
      end
    end

    def cost
      return @reported_cost if @reported_cost.positive?

      @price ? @input_tokens * @price / 1_000_000.0 : nil
    end

    def self.estimate(tokens, price)
      price ? tokens * price / 1_000_000.0 : nil
    end

    def to_h
      { "requests" => requests, "input_tokens" => input_tokens, "cost_usd" => cost&.round(6) }
    end

    def line
      cost_text = cost ? format("$%.4f", cost) : "cost unknown (set price_per_million)"
      "judgelint: #{requests} #{requests == 1 ? 'request' : 'requests'}, #{Usage.delimit(input_tokens)} input tokens, #{cost_text}"
    end

    def self.delimit(number)
      number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
