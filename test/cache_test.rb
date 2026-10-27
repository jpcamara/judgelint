# frozen_string_literal: true

require_relative "test_helper"

class CacheTest < Minitest::Test
  ENTRIES = {
    "a" * 64 => 0.25,
    "b" * 64 => { "breaks" => 0.125, "follows" => 0.75, "not_applicable" => 0.125 },
    "c" * 64 => nil,
    "d" * 64 => {},
    "e" * 64 => { "L1" => 0.5, "L2" => 0.5 }
  }.freeze

  def test_save_writes_what_pretty_generate_would
    in_tmp do
      cache = Judgelint::Cache.new("cache.json")
      ENTRIES.to_a.reverse_each { |key, value| cache.store(key, value) }
      cache.save

      assert_equal "#{JSON.pretty_generate(ENTRIES.sort.to_h)}\n", File.read("cache.json")
    end
  end

  def test_a_saved_file_is_read_back_entry_by_entry
    in_tmp do
      File.write("cache.json", "#{JSON.pretty_generate(ENTRIES)}\n")
      cache = Judgelint::Cache.new("cache.json")

      refute_empty cache.instance_variable_get(:@places)
      ENTRIES.each { |key, value| value.nil? ? assert_nil(cache.fetch(key)) : assert_equal(value, cache.fetch(key)) }
      ["0" * 64, "b" * 63 + "c", "f" * 64].each { |missing| assert_nil cache.fetch(missing) }
    end
  end

  def test_a_file_with_crlf_line_endings_is_read_entry_by_entry
    in_tmp do
      File.binwrite("cache.json", "#{JSON.pretty_generate(ENTRIES)}\n".gsub("\n", "\r\n"))
      cache = Judgelint::Cache.new("cache.json")

      refute_empty cache.instance_variable_get(:@places)
      ENTRIES.each { |key, value| value.nil? ? assert_nil(cache.fetch(key)) : assert_equal(value, cache.fetch(key)) }
    end
  end

  def test_new_answers_merge_with_the_file_in_key_order
    in_tmp do
      File.write("cache.json", "#{JSON.pretty_generate(ENTRIES.select { |key, _| key < 'c' })}\n")
      cache = Judgelint::Cache.new("cache.json")
      ENTRIES.each { |key, value| cache.store(key, value) if key >= "c" }
      cache.store("a" * 64, 0.5)
      cache.save

      expected = ENTRIES.merge("a" * 64 => 0.5)
      assert_equal "#{JSON.pretty_generate(expected.sort.to_h)}\n", File.read("cache.json")
      assert_equal 0.5, Judgelint::Cache.new("cache.json").fetch("a" * 64)
    end
  end

  def test_the_latest_answer_stored_under_a_key_wins
    in_tmp do
      cache = Judgelint::Cache.new("cache.json")
      cache.store("b" * 64, 0.25)
      cache.store("a" * 64, 0.5)
      cache.store("b" * 64, 0.75)

      assert_equal 0.75, cache.fetch("b" * 64)
      cache.save
      assert_equal "#{JSON.pretty_generate({ 'a' * 64 => 0.5, 'b' * 64 => 0.75 })}\n", File.read("cache.json")
    end
  end

  def test_a_scratch_file_that_cant_be_deleted_while_open_goes_when_saved
    in_tmp do
      cache = Judgelint::Cache.new("cache.json")
      delete = File.method(:delete)
      File.define_singleton_method(:delete) { |*paths| raise Errno::EACCES, paths.first }
      begin
        cache.store("a" * 64, 0.5)
      ensure
        File.define_singleton_method(:delete, delete)
      end
      scratch = "cache.json.#{Process.pid}.answers"

      assert File.exist?(scratch)
      cache.save
      refute File.exist?(scratch)
      assert_equal "#{JSON.pretty_generate({ 'a' * 64 => 0.5 })}\n", File.read("cache.json")
    end
  end

  def test_a_saved_cache_can_be_used_again
    in_tmp do
      cache = Judgelint::Cache.new("cache.json")
      cache.store("a" * 64, 0.5)
      cache.save
      cache.store("b" * 64, 0.25)

      assert_equal 0.5, cache.fetch("a" * 64)
      cache.save
      assert_equal "#{JSON.pretty_generate({ 'a' * 64 => 0.5, 'b' * 64 => 0.25 })}\n", File.read("cache.json")
    end
  end

  def test_a_file_in_another_form_is_read_whole_and_saved_in_key_order
    in_tmp do
      File.write("cache.json", JSON.generate(ENTRIES.to_a.reverse.to_h))
      cache = Judgelint::Cache.new("cache.json")

      assert_empty cache.instance_variable_get(:@places)
      assert_equal ENTRIES["b" * 64], cache.fetch("b" * 64)
      cache.store("f" * 64, 1.0)
      cache.save

      assert_equal "#{JSON.pretty_generate(ENTRIES.merge('f' * 64 => 1.0).sort.to_h)}\n", File.read("cache.json")
    end
  end

  def test_many_answers_merge_in_key_order
    in_tmp do
      random = Random.new(7)
      key = -> { format("%064x", random.rand(2**256)) }
      file = Array.new(300) { [key.call, random.rand.round(3)] }.to_h
      File.write("cache.json", "#{JSON.pretty_generate(file.sort.to_h)}\n")
      cache = Judgelint::Cache.new("cache.json")
      stored = Array.new(700) { [key.call, { "breaks" => random.rand.round(3) }] }.to_h
      stored[file.keys.first] = 0.5
      stored.each { |k, value| cache.store(k, value) }
      cache.store(stored.keys.last, 0.25)
      cache.save

      expected = file.merge(stored).merge(stored.keys.last => 0.25)
      assert_equal "#{JSON.pretty_generate(expected.sort.to_h)}\n", File.read("cache.json")
    end
  end

  def test_an_empty_cache_saves_as_an_empty_object
    in_tmp do
      File.write("cache.json", "{}\n")
      cache = Judgelint::Cache.new("cache.json")
      cache.store("a" * 64, 0.5)
      cache.save

      assert_equal "#{JSON.pretty_generate({ 'a' * 64 => 0.5 })}\n", File.read("cache.json")
    end
  end

  def test_a_bad_value_is_a_config_error
    in_tmp do
      File.write("cache.json", "{\n  \"#{'a' * 64}\": 0.5,\n  \"#{'b' * 64}\": nope\n}\n")

      error = assert_raises(Judgelint::ConfigError) { Judgelint::Cache.new("cache.json") }
      assert_match(/isn't valid JSON/, error.message)
    end
  end

  def test_keys_that_start_alike_are_told_apart
    entries = %w[1 5 9].to_h { |last| ["#{'7' * 63}#{last}", last.to_i] }
    in_tmp do
      File.write("cache.json", "#{JSON.pretty_generate(entries)}\n")
      cache = Judgelint::Cache.new("cache.json")

      entries.each { |key, value| assert_equal value, cache.fetch(key) }
      assert_nil cache.fetch("#{'7' * 63}3")
    end
  end

  def test_values_that_only_look_plain_are_still_checked
    key = "a" * 64
    ["{\n  \"#{key}\": 01\n}\n",
     "{\n  \"#{key}\": {\n    \"L1\": 0.5\n    \"L2\": 0.5\n  }\n}\n",
     "{\n  \"#{key}\": {\n    \"L1\": 0.5,\n  }\n}\n",
     "{\n  \"#{key}\": {\n    \"L1\": .5\n  }\n}\n",
     "{\n  \"#{key}\": {\n    \"L1\": NaN\n  }\n}\n"].each do |text|
      in_tmp do
        File.write("cache.json", text)
        error = assert_raises(Judgelint::ConfigError, text) { Judgelint::Cache.new("cache.json") }
        assert_match(/isn't valid JSON/, error.message)
      end
    end
  end

  def test_names_outside_the_plain_form_are_parsed_and_kept
    entries = { "a" * 64 => { "caf\u00e9.rb" => 0.5, "say \"hi\"\n" => 0.5 }, "b" * 64 => { "\u2603" => 1.0 } }
    in_tmp do
      File.write("cache.json", "#{JSON.pretty_generate(entries)}\n")
      cache = Judgelint::Cache.new("cache.json")

      refute_empty cache.instance_variable_get(:@places)
      entries.each { |key, value| assert_equal value, cache.fetch(key) }
    end
  end

  private

  def in_tmp(&block)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &block) }
  end
end
