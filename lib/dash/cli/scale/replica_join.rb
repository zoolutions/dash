# Adds replica slots of one role on one host, at the version the host already runs (the
# caller sets it on the config). A web replica joins the proxy pool only once healthy:
# dash-proxy waits for every target before it swaps. On failure the new containers are
# stopped and the replicas already running are left alone.
class Dash::Cli::Scale::ReplicaJoin
  SHORT_CONTAINER_ID_LENGTH = Dash::Cli::App::Boot::SHORT_CONTAINER_ID_LENGTH

  attr_reader :host, :role, :replicas, :sshkit
  delegate :execute, :capture_with_info, :upload!, :error, to: :sshkit

  # `running` is the slots already running on the host, which stay in the pool.
  def initialize(host, role, replicas, sshkit, running:)
    @host = host
    @role = role
    @replicas = replicas
    @sshkit = sshkit
    @running = running
  end

  def run
    execute *DASH.auditor(role: role).record_then("Scaled out to replicas #{replicas.join(", ")} at #{DASH.config.version}", app.ensure_env_directory)
    upload! role.secrets_io(host), role.secrets_path, mode: "0600"

    begin
      replicas.each { |replica| start(replica) }
      role.running_proxy? ? join_proxy : wait_for_ready
    rescue => e
      error "Failed to scale out #{role} on #{host}"
      replicas.each { |replica| execute *app(replica).stop(version: DASH.config.version), raise_on_non_zero_exit: false }
      raise e
    end
  end

  private
    # A scale-in stops a replica and leaves its container, so the slot's name can still be
    # taken by a stopped container of this version. `docker rm` refuses a running one, and
    # the slot is not running - that is why it is being added.
    def start(replica)
      execute *app(replica).remove_container(version: DASH.config.version), raise_on_non_zero_exit: false

      hostname = "#{host.to_s[0...51].chomp(".")}-#{SecureRandom.hex(6)}"
      capture_with_info(*app(replica).run(hostname: hostname))
    end

    # The whole pool, old replicas and new: a deploy replaces the service's target list, so a
    # missing id would drop a running replica from it.
    def join_proxy
      pool = (@running + replicas).sort
      targets = Dash::Cli::App::RunningTargets.new(sshkit, role: role, host: host).container_ids(replicas: pool)

      if targets.size != pool.size
        raise Dash::Cli::BootError, "Found #{targets.size} of the #{pool.size} replicas of #{role} on #{host} to pool, not changing the proxy"
      end

      execute *app.deploy(targets: targets.map { |id| id[0, SHORT_CONTAINER_ID_LENGTH] })
    end

    def wait_for_ready
      replicas.each do |replica|
        Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: role) do |mode, seconds_left = nil|
          if mode == :confirm
            capture_with_info(*app(replica).status(version: DASH.config.version))
          else
            capture_with_info *app(replica).wait_for_ready(version: DASH.config.version, timeout: seconds_left),
              interaction_handler: Dash::Cli::Healthcheck::ProgressReporter.new
          end
        end
      end
    end

    def app(replica = 1)
      DASH.app(role: role, host: host, replica: replica)
    end
end
