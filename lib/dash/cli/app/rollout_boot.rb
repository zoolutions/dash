class Dash::Cli::App::RolloutBoot
  attr_reader :host, :role, :version, :sshkit
  delegate :execute, :capture_with_info, :error, :upload!, to: :sshkit

  def initialize(host, role, sshkit, version)
    @host = host
    @role = role
    @version = version
    @sshkit = sshkit
  end

  def run
    ensure_not_already_deployed

    begin
      start_rollout_target
    rescue
      stop_rollout_target
      raise
    end
  rescue Dash::Cli::BootError => e
    error e.message
    raise
  end

  private
    def ensure_not_already_deployed
      if capture_with_info(*app.container_id_for_version(version), raise_on_non_zero_exit: false).present?
        raise Dash::Cli::BootError, "Version #{version} is already deployed for #{role} on #{host}, roll out a different version"
      end
    end

    def start_rollout_target
      audit "Booted rollout target version #{version}"
      hostname = "#{host.to_s[0...51].chomp(".")}-#{SecureRandom.hex(6)}"

      execute *app.ensure_env_directory
      upload! role.secrets_io(host), role.secrets_path, mode: "0600"

      execute *app.run(hostname: hostname)

      endpoint = capture_with_info(*app.container_id_for_version(version)).strip
      raise Dash::Cli::BootError, "Failed to get endpoint for #{role} on #{host}, did the container boot?" if endpoint.empty?

      execute *app.rollout_deploy(target: endpoint)
    end

    def stop_rollout_target
      execute *app.stop(version: version), raise_on_non_zero_exit: false
    end

    def app
      @app ||= DASH.app(role: role, host: host)
    end

    def audit(message)
      execute *DASH.auditor(role: role).record(message), verbosity: :debug
    end
end
