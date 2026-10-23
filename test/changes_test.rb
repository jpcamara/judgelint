# frozen_string_literal: true

require "test_helper"

class ChangesTest < Minitest::Test
  include ProjectHelpers

  DIFF = <<~DIFF
    diff --git a/app/a.rb b/app/a.rb
    index 1111111..2222222 100644
    --- a/app/a.rb
    +++ b/app/a.rb
    @@ -3 +3 @@ class A
    -  old
    +  new
    @@ -10,2 +10,0 @@ class A
    -  gone
    -  gone
    @@ -20,0 +19,3 @@ class A
    +  one
    +  two
    +  three
    diff --git a/app/with space.rb b/app/with space.rb
    new file mode 100644
    --- /dev/null
    +++ b/app/with space.rb\t
    @@ -0,0 +1,2 @@
    +x
    +y
    diff --git a/top.rb b/top.rb
    --- a/top.rb
    +++ b/top.rb
    @@ -1 +0,0 @@
    -only line
  DIFF

  def test_parses_changed_lines_from_hunks
    changed = Judgelint::Changes.parse_diff(DIFF)

    assert_equal [3, 10, 19, 20, 21], changed["app/a.rb"]
    assert_equal [1, 2], changed["app/with space.rb"]
    assert_equal [1], changed["top.rb"], "a deletion at the top marks line 1"
  end

  def test_refs_git_could_read_as_options_or_ranges
    %w[main origin/main v1.2.0 feature/x-y HEAD~1 HEAD^ 3f2a9c1].each { |ref| Judgelint::Changes.check_ref(ref) }
    ["-x", "--upload-pack=x", "a..b", "a b", ""].each do |ref|
      assert_raises(Judgelint::ConfigError, ref) { Judgelint::Changes.check_ref(ref) }
    end
  end

  def test_pr_base_comes_from_the_ci_environment
    fetched = []
    Judgelint::Changes.stub(:git, ->(*args) { fetched << args; "" }) do
      unset = Judgelint::Changes::BASE_BRANCH_VARIABLES.to_h { |name| [name, nil] }
      with_env(unset.merge("GITHUB_BASE_REF" => "main")) { assert_equal "origin/main", Judgelint::Changes.pr_base }
      with_env(unset.merge("SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/develop")) do
        assert_equal "origin/develop", Judgelint::Changes.pr_base
      end
      with_env(unset.merge("BUILDKITE_PULL_REQUEST_BASE_BRANCH" => "false", "JUDGELINT_BASE_BRANCH" => "trunk")) do
        assert_equal "origin/trunk", Judgelint::Changes.pr_base
      end
    end
    assert_equal(%w[main develop trunk].map { |branch| ["fetch", "--no-tags", "--quiet", "origin", branch] }, fetched)
  end

  private

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

class SourceTest < Minitest::Test
  include ProjectHelpers

  def test_numbers_lines_and_covers_the_file_with_windows
    in_project do
      write("a.rb", "one\ntwo\nthree")
      source = Judgelint::Source.new("a.rb", shown_as: "shown.rb")

      assert_equal "Path: shown.rb\n\n1: one\n2: two\n3: three\n", source.state
      assert_equal [[1, 2], [3, 3]], source.windows(2)
      assert_equal [[1, 3]], source.windows(40)
    end
  end

  def test_question_wording
    window = Judgelint::Question.new(rule, 41, 80)
    assert_equal "smell.41-80", window.key
    assert_equal "Look at lines 41-80 of the file; the rest is context. Does this code smell? " \
                 "Answer yes only when those lines do it, not when the question doesn't apply.", window.instructions

    file = Judgelint::Question.new(rule(scope: "file"), 1, 100)
    assert_equal "Does this code smell? Answer yes only when the code does it, not when the question doesn't apply.",
                 file.instructions

    validates = Judgelint::Question.new(rule(question: "Does it validate input first?", fail_when: "no"), 1, 100)
    assert_equal "Does it validate input first?", validates.instructions
  end
end

class PoolTest < Minitest::Test
  def test_keeps_order_and_raises_the_first_error_after_every_thread_finishes
    assert_equal [1, 4, 9], Judgelint::Pool.map([1, 2, 3], 3) { |n| n * n }

    finished = Queue.new
    error = assert_raises(ArgumentError) do
      Judgelint::Pool.map([1, 2, 3], 3) do |n|
        raise ArgumentError, "boom" if n == 1

        sleep 0.01
        finished << n
      end
    end
    assert_equal "boom", error.message
    assert_equal 2, finished.size
  end
end
