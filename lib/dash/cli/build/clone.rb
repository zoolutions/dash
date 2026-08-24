class Dash::Cli::Build::Clone
  attr_reader :sshkit
  delegate :info, :error, :execute, :capture_with_info, to: :sshkit

  def initialize(sshkit)
    @sshkit = sshkit
  end

  def prepare
    begin
      clone_repo
    rescue SSHKit::Command::Failed => e
      if e.message =~ /already exists and is not an empty directory/
        reset
      else
        raise Dash::Cli::Build::BuildError, "Failed to clone repo: #{e.message}"
      end
    end

    validate!
  rescue Dash::Cli::Build::BuildError => e
    error "Error preparing clone: #{e.message}, deleting and retrying..."

    FileUtils.rm_rf DASH.config.builder.clone_directory
    clone_repo
    validate!
  end

  private
    def clone_repo
      info "Cloning repo into build directory `#{DASH.config.builder.build_directory}`..."

      FileUtils.mkdir_p DASH.config.builder.clone_directory
      execute *DASH.builder.clone
    end

    def reset
      info "Resetting local clone as `#{DASH.config.builder.build_directory}` already exists..."

      DASH.builder.clone_reset_steps.each { |step| execute *step }
    rescue SSHKit::Command::Failed => e
      raise Dash::Cli::Build::BuildError, "Failed to clone repo: #{e.message}"
    end

    def validate!
      status = capture_with_info(*DASH.builder.clone_status).strip

      unless status.empty?
        raise Dash::Cli::Build::BuildError, "Clone in #{DASH.config.builder.build_directory} is dirty, #{status}"
      end

      revision = capture_with_info(*DASH.builder.clone_revision).strip
      if revision != Dash::Git.revision
        raise Dash::Cli::Build::BuildError, "Clone in #{DASH.config.builder.build_directory} is not on the correct revision, expected `#{Dash::Git.revision}` but got `#{revision}`"
      end
    rescue SSHKit::Command::Failed => e
      raise Dash::Cli::Build::BuildError, "Failed to validate clone: #{e.message}"
    end
end
