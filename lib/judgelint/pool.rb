# frozen_string_literal: true

module Judgelint
  # Maps items over a few threads and returns results in the items' order, so
  # output doesn't depend on which request came back first. The first error
  # is raised once every thread has finished.
  module Pool
    def self.map(items, size)
      results = Array.new(items.size)
      queue = Queue.new
      items.each_with_index { |item, index| queue << [item, index] }
      errors = []
      lock = Mutex.new
      threads = Array.new([[size, items.size].min, 1].max) do
        Thread.new do
          Thread.current.report_on_exception = false
          loop do
            pair = next_item(queue)
            break if pair.nil?

            begin
              results[pair[1]] = yield(pair[0])
            rescue StandardError => e
              lock.synchronize { errors << e }
            end
          end
        end
      end
      threads.each(&:join)
      raise errors.first unless errors.empty?

      results
    end

    def self.next_item(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end
  end
end
