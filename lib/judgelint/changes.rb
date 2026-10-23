# frozen_string_literal: true

module Judgelint
  # The lines a change touched, from git: everything since the merge base with
  # a ref, uncommitted work included. Old code outside the change isn't asked
  # about, so it can't block new work.
  module Changes
    # A branch, tag, or commit (HEAD~1 too), and nothing git could read as an
    # option or a range.
    REF = %r{\A[A-Za-z0-9][A-Za-z0-9._/~^-]*\z}
    HUNK = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

    # Returns {path => [changed line numbers]}, or :all for a new file.
    def self.since(ref)
      check_ref(ref)
      base = git("merge-base", ref, "HEAD").strip
      changed = parse_diff(git("-c", "core.quotePath=false", "diff", "-U0", "--no-color", "--no-ext-diff",
                               "--relative", "--diff-filter=d", base))
      git("ls-files", "--others", "--exclude-standard").lines.each { |path| changed[path.chomp] = :all }
      changed
    end

    # CI variables that name a pull request's base branch.
    BASE_BRANCH_VARIABLES = %w[
      JUDGELINT_BASE_BRANCH GITHUB_BASE_REF CI_MERGE_REQUEST_TARGET_BRANCH_NAME
      BUILDKITE_PULL_REQUEST_BASE_BRANCH BITBUCKET_PR_DESTINATION_BRANCH SYSTEM_PULLREQUEST_TARGETBRANCH
    ].freeze

    # The pull request's base branch, fetched, as origin/<branch>: from
    # JUDGELINT_BASE_BRANCH, then GitHub Actions, GitLab, Buildkite, Bitbucket,
    # or Azure Pipelines, then the gh CLI.
    def self.pr_base
      branch = pr_branch
      raise ConfigError, "Couldn't find the pull request's base branch" if branch.empty?

      check_ref(branch)
      git("fetch", "--no-tags", "--quiet", "origin", branch)
      "origin/#{branch}"
    end

    def self.pr_branch
      BASE_BRANCH_VARIABLES.each do |name|
        # Buildkite sets "false" outside a pull request; Azure names a full ref.
        branch = ENV.fetch(name, "").delete_prefix("refs/heads/")
        return branch unless branch.empty? || branch == "false"
      end
      command("gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName").strip
    end

    def self.parse_diff(diff)
      changed = {}
      path = nil
      diff.each_line do |line|
        if line.start_with?("+++ ")
          target = line.chomp.delete_prefix("+++ ").delete_suffix("\t")
          path = target == "/dev/null" ? nil : target.delete_prefix("b/")
        elsif path && (hunk = HUNK.match(line))
          start = hunk[1].to_i
          count = hunk[2] ? hunk[2].to_i : 1
          # A pure deletion marks the line above the gap, so it's still judged.
          lines = count.zero? ? [[start, 1].max] : (start...(start + count)).to_a
          (changed[path] ||= []).concat(lines)
        end
      end
      changed
    end

    def self.check_ref(ref)
      return if REF.match?(ref) && !ref.include?("..")

      raise ConfigError, "Not a usable git ref: #{ref}"
    end

    def self.git(*args)
      command("git", *args)
    end

    def self.command(*args)
      out, err, status = Open3.capture3(*args)
      raise ConfigError, "#{args.first(3).join(' ')} failed: #{err.strip.lines.first.to_s.strip}" unless status.success?

      out
    rescue SystemCallError => e
      raise ConfigError, "Couldn't run #{args.first}: #{e.message}"
    end
  end
end
