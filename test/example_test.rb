# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# Replays examples/scoop-society from its committed cache, with the network
# pointed nowhere, and checks the verdicts against expected.json: every listed
# violation but the known misses is found, and nothing else is a violation
# except the arguable ones. A changed rule or file is a cache miss, which
# fails here until `rake example` re-records it.
class ExampleTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXAMPLE = File.join(ROOT, "examples", "scoop-society")

  def test_finds_the_demos_known_violations
    spec = JSON.parse(File.read(File.join(EXAMPLE, "expected.json")))
    pairs = ->(list) { list.map { |violation| [violation["path"], violation["rule"]] } }
    expected = (pairs.call(spec["violations"]) - pairs.call(spec["missed"])).sort
    arguable = pairs.call(spec["arguable"])

    Dir.mktmpdir("judgelint-example") do |dir|
      config = File.join(dir, "offline.yml")
      File.write(config, "models: [{provider: typesafe, api_base: \"http://127.0.0.1:1\"}]\n" \
                         "ignore: [\"src/services/_*\", \"src/generated/**\"]\n")
      runners.each do |name, command|
        out, err, status = Open3.capture3({ "TYPESAFE_API_KEY" => nil }, *command, "--config", config,
                                          "--format", "json", chdir: EXAMPLE)
        assert_equal 1, status.exitstatus, "#{name}: #{err}"

        data = JSON.parse(out)
        found = data["results"].select { |result| result["status"] == "violation" }
                               .map { |result| [result["path"], result["rule"]] }.sort
        assert_equal expected, (found - arguable), name
        assert_equal 0, data["usage"]["requests"], "#{name}: every answer should come from the cache"
      end
    end
  end

  # examples/conventions: each spec's Bad and Good blocks, and the code beside
  # it, as Jev judged them. Replayed from the cache, with no key.
  CONVENTIONS = {
    "ruby" => [%w[app/jobs/sync_invoices_job.rb root/jobs-take-ids-not-records],
               %w[app/jobs/sync_invoices_job.rb root/no-silent-rescues],
               %w[app/services/charge_card.rb root/service-objects-return-a-result]],
    "typescript" => [%w[src/components/Banner.tsx root/text-users-see-goes-through-t],
                     %w[src/components/ProfileCard.tsx root/components-don-t-fetch]],
    "python" => [%w[src/pipeline/clean.py root/log-don-t-print],
                 %w[src/pipeline/export.py root/network-calls-have-a-timeout]],
    "sql" => [%w[db/migrations/20261025_add_carrier.sql root/every-migration-can-be-undone],
              %w[db/migrations/20261025_add_carrier.sql root/indexes-are-built-concurrently],
              %w[db/migrations/20261025_add_carrier.sql root/new-columns-on-existing-tables-are]]
  }.freeze

  def test_the_convention_examples
    CONVENTIONS.each do |language, expected|
      dir = File.join(ROOT, "examples", "conventions", language)
      runners.each do |name, command|
        out, err, status = Open3.capture3({ "TYPESAFE_API_KEY" => nil }, *command, "--format", "json", chdir: dir)
        assert_equal 1, status.exitstatus, "#{language} #{name}: #{err}"
        data = JSON.parse(out)
        found = data["results"].select { |result| result["status"] == "violation" }
                               .map { |result| [result["path"], result["rule"]] }.sort
        assert_equal expected, found, "#{language} #{name}"
        assert_equal 0, data["usage"]["requests"], "#{language} #{name}: every answer should come from the cache"

        out, err, status = Open3.capture3({ "TYPESAFE_API_KEY" => nil }, *command, "test", "--format", "json", chdir: dir)
        assert_equal 0, status.exitstatus, "#{language} #{name}: #{err}"
        assert_equal JSON.parse(out)["total"], JSON.parse(out)["correct"], "#{language} #{name}"
      end
    end
  end

  private

  def runners
    runners = { "exe" => ["ruby", "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe/judgelint")] }
    binary = ENV.fetch("JUDGELINT_BINARY", nil)
    runners["spinel"] = [binary] if binary
    runners
  end
end
