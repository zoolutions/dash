require "fileutils"

# Moves a project from the legacy `.kamal` directory to `.dash`. Purely local -
# it never opens an SSH connection and never reads deploy.yml - and only ever
# runs when the operator asks for it, because silently rewriting someone's
# working tree is not a deploy tool's job.
#
# Returns [message, color] pairs rather than printing: output belongs to the Thor
# command, and reaching into the Thor instance for `say` couples this class to a
# shell helper whose visibility changes between Thor versions.
class Dash::Cli::Main::Migrate
  CURRENT = Dash::ProjectDirectory::CURRENT
  LEGACY = Dash::ProjectDirectory::LEGACY

  LEGACY_ENV_PATTERN = /\bKAMAL_[A-Z0-9_]+/
  EXTRA_SCANNED_FILES = [ "config/deploy.yml" ].freeze

  attr_reader :dry_run

  def initialize(dry_run: false)
    @dry_run = dry_run
  end

  def run
    return [ [ "No #{LEGACY} directory to migrate.", nil ] ] unless Dir.exist?(LEGACY)

    if Dir.exist?(CURRENT)
      return [ [ "Both #{CURRENT} and #{LEGACY} exist. Merge them by hand, then remove #{LEGACY}.", :yellow ] ]
    end

    if dry_run
      [ [ "Would move #{LEGACY} to #{CURRENT}#{" with git mv" if tracked_by_git?}", nil ], *legacy_env_reference_lines ]
    else
      move
      [ [ "Moved #{LEGACY} to #{CURRENT}", :green ], *legacy_env_reference_lines ]
    end
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
    def legacy_env_reference_lines
      references = scanned_files.filter_map do |file|
        names = File.read(file, encoding: Encoding::BINARY).scan(LEGACY_ENV_PATTERN).uniq
        [ file, names ] if names.any?
      end

      return [] if references.empty?

      [
        [ "\nFound legacy KAMAL_* references. dash sets both prefixes until 5.0, so nothing is urgent:", nil ],
        *references.map { |file, names| [ "  #{file}: #{names.sort.join(", ")}", nil ] }
      ]
    end

    def scanned_files
      directory = dry_run ? LEGACY : CURRENT

      (Dir.glob("#{directory}/**/*") + EXTRA_SCANNED_FILES).select { |file| File.file?(file) && File.readable?(file) }
    end
end
