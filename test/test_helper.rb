# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "json"
require "fileutils"
require "open3"

# The binary under test: target/release/judgelint, or JUDGELINT_BINARY.
BINARY = ENV.fetch("JUDGELINT_BINARY", File.expand_path("../target/release/judgelint", __dir__))
VERSION = File.read(File.expand_path("../Cargo.toml", __dir__))[/^version = "(.+)"/, 1]

# A decision-model endpoint on localhost that answers both protocols. Every
# question answers yes with probability 0.9 when the state contains "SMELL",
# and 0.1 otherwise. Pass responses (each [status, body] or [status, body,
# headers]) to answer requests in order instead; the last one repeats. Or
# pass a block, which answers each System One question from the state and
# the question's key: with a yes probability, a choice's probabilities by
# option, or nil to refuse.
#
# +together+ holds every answer until that many requests have come in, or
# three seconds pass, which sets +apart+. +hang_up+ closes that many
# connections first, without answering.
class StubSystemOne
  attr_reader :requests, :apart

  def initialize(status: 200, body: nil, responses: nil, together: nil, hang_up: 0, &answer)
    @server = TCPServer.new("127.0.0.1", 0)
    @responses = responses || (body ? [[status, body]] : nil)
    @answer = answer
    @together = together
    @hang_up = hang_up
    @apart = false
    @requests = []
    @thread = Thread.new { loop { accept(@server.accept) } }
  end

  def base
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def accept(client)
    if @hang_up.positive?
      @hang_up -= 1
      client.close
    elsif @together
      Thread.new { serve(client) }
    else
      serve(client)
    end
  end

  def serve(client)
    request_line = client.gets
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    payload = JSON.parse(client.read(headers.fetch("content-length").to_i))
    @requests << { path: request_line.split[1], authorization: headers["authorization"], headers: headers,
                   payload: payload }
    wait_for_the_rest if @together
    respond(client, payload)
  ensure
    client.close
  end

  def wait_for_the_rest
    deadline = Time.now + 3
    sleep 0.01 while @requests.size < @together && Time.now < deadline
    @apart = true if @requests.size < @together
  end

  def respond(client, payload)
    status, body, extra = @responses ? @responses[[@requests.size - 1, @responses.size - 1].min] : [200, nil]
    body ||= JSON.generate(answers_for(payload))
    body = JSON.generate(body) unless body.is_a?(String)
    head = (extra || {}).map { |name, value| "#{name}: #{value}\r\n" }.join
    client.write "HTTP/1.1 #{status} Stub\r\nContent-Type: application/json\r\n#{head}" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def answers_for(payload)
    state = payload["state"] || payload["input"]
    yes = state.to_s.include?("SMELL") ? 0.9 : 0.1
    usage = { "input_tokens" => 10, "output_tokens" => 0 }
    if payload.key?("input")
      answers = payload["questions"].map do |q|
        next { "type" => "predicate", "name" => q["name"], "probability" => yes } unless q["type"] == "choice"

        spread = self.class.spread(q["choices"].map { |choice| choice["value"] }, yes)
        { "type" => "choice", "name" => q["name"], "probabilities" => spread.map { |value, p| { "value" => value, "probability" => p } } }
      end
      return { "model" => payload["model"], "answers" => answers, "usage" => usage }
    end

    answers = payload["questions"].to_h do |key, q|
      options = q["criteria"].keys if q["type"] == "choice"
      [key, answer(@answer ? @answer.call(payload["state"], key) : yes, options)]
    end
    { "model" => "#{payload['model']}-stub", "usage" => usage, "answers" => answers }
  end

  # A System One answer: nil refuses, and a yes probability for a choice is
  # spread over its options.
  def answer(value, options)
    return { "type" => "refusal" } if value.nil?
    return { "type" => "noul", "noul" => value } unless options

    { "type" => "choice", "probabilities" => value.is_a?(Hash) ? value : self.class.spread(options, value) }
  end

  # A choice's answer for a yes probability: "breaks" gets it, or, for a
  # "where" question, the first option gets everything.
  def self.spread(options, yes)
    return options.to_h { |option| [option, option == options.first ? 1.0 : 0.0] } unless options.include?("breaks")

    { "breaks" => yes, "follows" => 1.0 - yes, "not_applicable" => 0.0 }
  end
end

module ProjectHelpers
  def in_project
    Dir.mktmpdir("judgelint") do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_rule(id, question: "Does this code smell?", extra: "")
    write(".judgelint/rules/#{id}.md", <<~MARKDOWN)
      ---
      question: #{question}
      paths: ["app/**/*.rb"]
      #{extra}
      ---
      Smelly code is hard to change.
    MARKDOWN
  end

  def in_smelly_project(&)
    in_project do |dir|
      write_rule("smell")
      write("app/bad.rb", "SMELL\n")
      write("app/good.rb", "fine\n")
      write("lib/ignored.rb", "SMELL\n")
      yield dir
    end
  end

  # Runs the binary in the current project against +server+, as Jev on
  # TypeSafe with +model+'s settings on top; +config+ adds top-level
  # settings. Every run passes --no-cache unless +cache+. Returns [status,
  # stdout, stderr].
  def judgelint(*args, server: @server, model: {}, config: {}, env: {}, cache: false)
    write_config(server: server, model: model, config: config)
    out, err, status = Open3.capture3({ "JUDGELINT_TEST_KEY" => "secret" }.merge(env), BINARY, *args,
                                      *("--no-cache" unless cache))
    [status.exitstatus, out, err]
  end

  # The .judgelint.yml #judgelint writes.
  def write_config(server: @server, model: {}, config: {})
    entry = { "provider" => "typesafe", "api_base" => server.base, "api_key_env" => "JUDGELINT_TEST_KEY" }.merge(model)
    write(".judgelint.yml", JSON.generate({ "models" => [entry] }.merge(config)))
  end

  # Commits the project on main, as a repository judgelint can diff against.
  def git_repo
    git("init", "-q", "-b", "main")
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "add", "-A")
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "start")
  end

  def git(*args)
    _out, err, status = Open3.capture3("git", *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?
  end
end
