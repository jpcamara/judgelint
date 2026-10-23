# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "judgelint"

# A System One endpoint on localhost. Every question answers yes with
# probability 0.9 when the state contains "SMELL", and 0.1 otherwise.
class StubSystemOne
  attr_reader :requests

  def initialize(status: 200, body: nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @status = status
    @body = body
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
    @requests << { path: request_line.split[1], authorization: headers["authorization"], payload: payload }
    respond(client, payload)
  ensure
    client.close
  end

  def respond(client, payload)
    body = @body || JSON.generate(answers_for(payload))
    reason = @status == 200 ? "OK" : "Error"
    client.write "HTTP/1.1 #{@status} #{reason}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def answers_for(payload)
    yes = payload["state"].to_s.include?("SMELL") ? 0.9 : 0.1
    answers = payload["questions"].keys.to_h { |key| [key, { "type" => "noul", "noul" => yes }] }
    { "model" => "#{payload['model']}-stub", "usage" => { "input_tokens" => 10, "output_tokens" => 1 },
      "answers" => answers }
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
    Judgelint::ConfigLoader.build({ "cache" => false }.merge(overrides.transform_keys(&:to_s)))
  end

  def rule(id = "smell", **fields)
    defaults = {
      id: id, question: "Does this code smell?", yes_means: nil, no_means: nil, fail_when: "yes",
      paths: ["app/**/*.rb"], excludes: [], severity: "error", threshold: 0.7, message: "Smells.",
      source: ".judgelint/rules/#{id}.md"
    }
    Judgelint::Rule.new(**defaults.merge(fields))
  end
end
