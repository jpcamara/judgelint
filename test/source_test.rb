# frozen_string_literal: true

require "test_helper"

class SourceTest < Minitest::Test
  include ProjectHelpers

  def test_the_first_state_comes_from_the_read_that_planned_it
    in_project do
      write("app/a.rb", "x # judgehint: kept short\n")
      source = Judgelint::Source.new("app/a.rb")
      write("app/a.rb", "y\nz\n")

      assert_equal [1, true], [source.line_count, source.hinted?(1, 1)]
      assert_equal "Path: app/a.rb\n\n1: x # judgehint: kept short\n", source.state
      assert_equal "Path: app/a.rb\n\n1: y\n2: z\n", source.state
    end
  end
end
