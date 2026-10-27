# frozen_string_literal: true

module Judgelint
  # Stores each answer under a hash of everything that produced it: the state
  # the model saw (path and numbered contents), the question asked of it, and
  # the model. Changing any of them is a miss. Safe to share across threads.
  #
  # A cache file in the form #save writes stays on disk: loading it checks
  # every entry and keeps its key and where it is, and a lookup finds the
  # key by binary search and reads that entry back. Any other JSON object is
  # read whole. New answers wait for #save in a scratch file beside the
  # cache, already in the form it writes. A run saves its cache once, when
  # it's done.
  class Cache
    # A line that starts an entry: its key, then its value or the value's
    # first line.
    ENTRY = /\A  "([0-9a-f]{64})": (.*)\n\z/
    KEY_SIZE = 64
    # Where a value starts in its entry's first line.
    VALUE_AT = 70
    # A value's place in a file is kept as one Integer: its offset, shifted
    # past its length.
    SPAN_BITS = 32

    def initialize(path)
      @path = path
      @keys = +"" # the file's keys in order, end to end
      @places = [] # the place of each key's value in the file
      @entries = {} # every answer from a file read whole, or stored without a file
      @stored_keys = +"" # the keys of answers stored this run, end to end, in the order stored
      @stored_places = [] # the place of each in the scratch file
      @dirty = false
      @lock = Mutex.new
      load_entries
    end

    def self.key(question_digest, state_digest, model_label)
      Digest::SHA256.hexdigest([question_digest, state_digest, model_label].join(":"))
    end

    def fetch(key)
      @lock.synchronize do
        if (stored = stored(key))
          read(@scratch, @stored_places[stored])
        elsif (found = find(key))
          read(@file, @places[found])
        else
          @entries[key]
        end
      end
    end

    def store(key, yes_probability)
      @lock.synchronize do
        @dirty = true
        if @path
          text = JSON.pretty_generate(yes_probability)
          @scratch ||= scratch
          @stored_keys << key
          @stored_places << place(@scratch_size, text.bytesize)
          @scratch.write(text)
          @scratch.flush
          @scratch_size += text.bytesize
        else
          @entries[key] = yes_probability
        end
      end
    end

    # Writes every entry in key order, as JSON.pretty_generate does, one at a
    # time into a new file that then replaces the old one.
    def save
      @lock.synchronize do
        return unless @path && @dirty

        FileUtils.mkdir_p(File.dirname(@path))
        temp = "#{@path}.#{Process.pid}.tmp"
        File.open(temp, "w") { |out| write(out) }
        close
        File.rename(temp, @path)
        @dirty = false
      end
    end

    private

    # The index of +key+ among the file's keys, or nil.
    def find(key)
      low = 0
      high = @places.size - 1
      while low <= high
        middle = (low + high) / 2
        other = @keys.byteslice(middle * KEY_SIZE, KEY_SIZE)
        return middle if other == key

        other < key ? low = middle + 1 : high = middle - 1
      end
      nil
    end

    # The latest answer stored this run under +key+, or nil. A run looks its
    # answers up before it stores any, so there are rarely any to look at.
    def stored(key)
      index = @stored_places.size - 1
      while index >= 0
        return index if @stored_keys.byteslice(index * KEY_SIZE, KEY_SIZE) == key

        index -= 1
      end
      nil
    end

    def read(file, at)
      JSON.parse(raw(file, at))
    end

    def raw(file, at)
      file.pread(at & ((1 << SPAN_BITS) - 1), at >> SPAN_BITS)
    end

    def place(offset, length)
      (offset << SPAN_BITS) | length
    end

    # Deleted as soon as it's open where the system allows that, so it goes
    # away with the process; elsewhere, once the cache is saved.
    def scratch
      FileUtils.mkdir_p(File.dirname(@path))
      path = "#{@path}.#{Process.pid}.answers"
      file = File.open(path, "w+")
      begin
        File.delete(path)
      rescue SystemCallError
        @scratch_path = path
      end
      @scratch_size = 0
      file
    end

    # The file can't be replaced while it's open everywhere.
    def close
      @file&.close
      @scratch&.close
      File.delete(@scratch_path) if @scratch_path
    end

    # Merges the file's entries, or those read whole, with the answers stored
    # this run, which replace any with the same key.
    def write(out)
      whole = @entries.keys.sort
      kept = whole.empty? ? @places.size : whole.size
      count = 0
      i = 0
      stored_buckets.each do |bucket|
        keys = bucket.map { |index| @stored_keys.byteslice(index * KEY_SIZE, KEY_SIZE) }
        latest(keys).each do |n|
          key = keys[n]
          while i < kept && (mine = kept_key(whole, i)) < key
            count = entry(out, count, mine, kept_text(whole, i))
            i += 1
          end
          i += 1 if i < kept && kept_key(whole, i) == key
          count = entry(out, count, key, raw(@scratch, @stored_places[bucket[n]]))
        end
      end
      while i < kept
        count = entry(out, count, kept_key(whole, i), kept_text(whole, i))
        i += 1
      end
      out.write(count.zero? ? "{}\n" : "\n}\n")
    end

    def entry(out, count, key, text)
      out.write(count.zero? ? "{\n" : ",\n")
      out.write("  #{JSON.generate(key)}: #{text.gsub("\n", "\n  ")}")
      count + 1
    end

    def kept_key(whole, index)
      whole.empty? ? @keys.byteslice(index * KEY_SIZE, KEY_SIZE) : whole[index]
    end

    def kept_text(whole, index)
      JSON.pretty_generate(whole.empty? ? read(@file, @places[index]) : @entries[whole[index]])
    end

    # The answers stored this run, by the first two hex digits of their keys:
    # in key order a bucket at a time, so only one bucket's keys are out at
    # once.
    def stored_buckets
      buckets = Array.new(256) { [] }
      @stored_places.size.times do |index|
        at = index * KEY_SIZE
        buckets[(digit(@stored_keys.getbyte(at)) << 4) | digit(@stored_keys.getbyte(at + 1))] << index
      end
      buckets
    end

    def digit(byte)
      byte < 97 ? byte - 48 : byte - 87
    end

    # The indexes of +keys+ in key order, keeping the latest of any stored twice.
    def latest(keys)
      found = []
      (0...keys.size).sort_by { |index| keys[index] }.each do |index|
        if !found.empty? && keys[found.last] == keys[index]
          found[-1] = index if index > found.last
        else
          found << index
        end
      end
      found
    end

    def load_entries
      return unless @path && File.exist?(@path)

      @file = File.open(@path, "rb")
      return if index

      @keys = +""
      @places = []
      data = JSON.parse(File.read(@path))
      raise ConfigError, "#{@path} isn't a judgelint cache; delete it to start over" unless data.is_a?(Hash)

      @entries = data
    rescue JSON::ParserError
      raise ConfigError, "#{@path} isn't valid JSON; delete it to start over"
    end

    # Indexes a file in the form #save writes, with its keys in order, parsing
    # each value once to check it. False for anything else.
    def index
      offset = 0
      last = nil # the latest key
      open = false # inside a value that spans lines
      start = 0
      text = +""
      ended = false # read the entry without a comma
      closed = false # read the final brace
      @file.each_line do |line|
        return false if closed

        if offset.zero?
          return false unless line == "{\n" || line == "{}\n"

          closed = line == "{}\n"
        elsif open
          if line.start_with?("    ")
            text << line
          elsif line == "  }\n" || line == "  },\n"
            text << "  }"
            return false unless indexed(last, start, text)

            open = false
            ended = line == "  }\n"
          else
            return false
          end
        elsif ended
          return false unless line == "}\n"

          closed = true
        else
          match = ENTRY.match(line)
          return false unless match && (last.nil? || last < match[1])

          last = match[1]
          rest = match[2]
          start = offset + VALUE_AT
          if rest == "{"
            open = true
            text = +"{\n"
          else
            ended = !rest.end_with?(",")
            return false unless indexed(last, start, ended ? rest : rest.delete_suffix(","))
          end
        end
        offset += line.bytesize
      end
      closed
    end

    def indexed(key, start, text)
      JSON.parse(text)
      @keys << key
      @places << place(start, text.bytesize)
      true
    rescue JSON::ParserError
      false
    end
  end
end
