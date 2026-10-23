# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "judgelint"

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
      answers = payload["questions"].map { |q| { "type" => "predicate", "name" => q["name"], "probability" => yes } }
      return { "model" => payload["model"], "answers" => answers, "usage" => usage }
    end

    answers = payload["questions"].keys.to_h { |key| [key, { "type" => "noul", "noul" => yes }] }
    { "model" => "#{payload['model']}-stub", "usage" => usage, "answers" => answers }
  end
end

# Answers from a table instead of a model, and counts calls.
class FakeClient
  attr_reader :calls

  def initialize(&answer)
    @answer = answer
    @calls = []
  end

  def judge(state, rules)
    @calls << [state, rules.map(&:id)]
    rules.to_h { |rule| [rule.question_key, @answer.call(state, rule)] }
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

  def config(**overrides)
    Judgelint::Config.new({ "cache" => false }.merge(overrides.transform_keys(&:to_s)))
  end

  # A rule as its frontmatter would declare it.
  def rule(id = "smell", **fields)
    data = { "question" => "Does this code smell?", "paths" => ["app/**/*.rb"], "message" => "Smells." }
    Judgelint::Rule.new(data.merge(fields.transform_keys(&:to_s)), source: ".judgelint/rules/#{id}.md")
  end
end
