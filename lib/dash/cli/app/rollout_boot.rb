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
      if replicas.any? { |replica| capture_with_info(*app(replica).container_id_for_version(version), raise_on_non_zero_exit: false).present? }
        raise Dash::Cli::BootError, "Version #{version} is already deployed for #{role} on #{host}, roll out a different version"
      end
    end

    # The rollout target is as many replicas as the live version runs, so a canary split
    # compares like with like.
    def start_rollout_target
      audit "Booted rollout target version #{version}"

      execute *app.ensure_env_directory
      upload! role.secrets_io(host), role.secrets_path, mode: "0600"

      endpoints = replicas.map do |replica|
        hostname = "#{host.to_s[0...51].chomp(".")}-#{SecureRandom.hex(6)}"
        execute *app(replica).run(hostname: hostname)

        capture_with_info(*app(replica).container_id_for_version(version)).strip.tap do |endpoint|
          raise Dash::Cli::BootError, "Failed to get endpoint for #{role} on #{host}, did the container boot?" if endpoint.empty?
        end
      end

      execute *app.rollout_deploy(targets: endpoints)
    end

    def stop_rollout_target
      replicas.each do |replica|
        execute *app(replica).stop(version: version), raise_on_non_zero_exit: false
      end
    end

    # A role without replicas is one slot, and asks nothing more than it always did.
    def replicas
      @replicas ||=
        if role.replicas.scalable?
          names = capture_with_info(*app.active_containers).lines.map(&:strip)
          (1..role.replicas.clamp(names.filter_map { |name| role.replica_from_name(name) }.uniq.size)).to_a
        else
          [ 1 ]
        end
    end

    def app(replica = 1)
      @apps ||= {}
      @apps[replica] ||= DASH.app(role: role, host: host, replica: replica)
    end

    def audit(message)
      execute *DASH.auditor(role: role).record(message), verbosity: :debug
    end
end
