# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "json"
require "fileutils"

# The binary under test: target/release/judgelint, or JUDGELINT_BINARY.
BINARY = ENV.fetch("JUDGELINT_BINARY", File.expand_path("../target/release/judgelint", __dir__))
VERSION = File.read(File.expand_path("../Cargo.toml", __dir__))[/^version = "(.+)"/, 1]

# A decision-model endpoint on localhost that answers both protocols. Every
# question answers yes with probability 0.9 when the state contains "SMELL",
# and 0.1 otherwise. Pass responses (each [status, body] or [status, body,
# headers]) to answer requests in order instead; the last one repeats.
class StubSystemOne
  attr_reader :requests

  def initialize(status: 200, body: nil, responses: nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @responses = responses || (body ? [[status, body]] : nil)
    @requests = []
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def base
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

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
    respond(client, payload)
  ensure
    client.close
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
      next [key, { "type" => "noul", "noul" => yes }] unless q["type"] == "choice"

      [key, { "type" => "choice", "probabilities" => self.class.spread(q["criteria"].keys, yes) }]
    end
    { "model" => "#{payload['model']}-stub", "usage" => usage, "answers" => answers }
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

end
