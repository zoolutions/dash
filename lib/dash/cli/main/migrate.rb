require "fileutils"

# Moves a project from the legacy `.kamal` directory to `.dash`. Purely local -
# it never opens an SSH connection and never reads deploy.yml - and only ever
# runs when the operator asks for it, because silently rewriting someone's
# working tree is not a deploy tool's job.
class Dash::Cli::Main::Migrate
  CURRENT = Dash::ProjectDirectory::CURRENT
  LEGACY = Dash::ProjectDirectory::LEGACY

  LEGACY_ENV_PATTERN = /\bKAMAL_[A-Z0-9_]+/
  EXTRA_SCANNED_FILES = [ "config/deploy.yml" ].freeze

  attr_reader :shell, :dry_run
  delegate :say, to: :shell

  def initialize(shell, dry_run: false)
    @shell = shell
    @dry_run = dry_run
  end

  def run
    unless Dir.exist?(LEGACY)
      say "No #{LEGACY} directory to migrate."
      return
    end

    if Dir.exist?(CURRENT)
      say "Both #{CURRENT} and #{LEGACY} exist. Merge them by hand, then remove #{LEGACY}.", :yellow
      return
    end

    if dry_run
      say "Would move #{LEGACY} to #{CURRENT}#{" with git mv" if tracked_by_git?}"
    else
      move
      say "Moved #{LEGACY} to #{CURRENT}", :green
    end

    report_legacy_env_references
  end

  private
    # `git mv` stages the rename, so the operator is left with a clean rename in
    # `git status` rather than a delete plus a pile of untracked files.
    def move
      if tracked_by_git?
        system("git", "mv", LEGACY, CURRENT, exception: true)
      else
        FileUtils.mv LEGACY, CURRENT
      end
    end

    def tracked_by_git?
      return @tracked_by_git if defined?(@tracked_by_git)
      @tracked_by_git = !`git ls-files -- #{LEGACY} 2> /dev/null`.strip.empty?
    end

    # Reported, never rewritten: both prefixes carry the same value until 5.0,
    # so there is nothing to fix today and an automatic rewrite of hook scripts
    # would be a much bigger promise than this command makes.
    def report_legacy_env_references
      references = scanned_files.filter_map do |file|
        names = File.read(file, encoding: Encoding::BINARY).scan(LEGACY_ENV_PATTERN).uniq
        [ file, names ] if names.any?
      end

      return if references.empty?

      say "\nFound legacy KAMAL_* references. dash sets both prefixes until 5.0, so nothing is urgent:"
      references.each { |file, names| say "  #{file}: #{names.sort.join(", ")}" }
    end

    def scanned_files
      directory = dry_run ? LEGACY : CURRENT

      (Dir.glob("#{directory}/**/*") + EXTRA_SCANNED_FILES).select { |file| File.file?(file) && File.readable?(file) }
    end
end
