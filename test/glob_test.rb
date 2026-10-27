# frozen_string_literal: true

require "test_helper"

class GlobTest < Minitest::Test
  include ProjectHelpers

  def test_a_symlink_to_itself_is_skipped
    in_project do
      write("app/a.rb", "a")
      write("app/sub/b.rb", "b")
      File.symlink("self", "app/self")

      assert_raises(Errno::ELOOP) { Dir.glob("app/*/*") }
      assert_equal ["app/sub/b.rb"], Judgelint::Glob.glob("app/*/*")
      assert_equal [], Judgelint::Glob.glob("app/self/**/*")
      assert_equal %w[app/a.rb app/sub/b.rb], Judgelint::Glob.expand(["app/**/*", "{app,lib}/*/*.rb"])
    end
  end
end
