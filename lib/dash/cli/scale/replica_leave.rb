# Removes replica slots of one role on one host, gracefully. A web replica leaves the proxy
# pool first - the redeploy without it drains its in-flight requests - and only then stops.
# A worker replica is sent its drain signal and given its drain wait before `docker stop`,
# whose own timeout is the role's stop budget.
class Dash::Cli::Scale::ReplicaLeave
  SHORT_CONTAINER_ID_LENGTH = Dash::Cli::App::Boot::SHORT_CONTAINER_ID_LENGTH

  attr_reader :host, :role, :leaving, :sshkit
  delegate :execute, :info, to: :sshkit

  # `leaving` is { replica => running version }; `running` is every slot running on the host.
  def initialize(host, role, leaving, sshkit, running:)
    @host = host
    @role = role
    @leaving = leaving
    @sshkit = sshkit
    @running = running
  end

  def run
    execute *DASH.auditor(role: role).record("Scaled in replicas #{leaving.keys.join(", ")}"), verbosity: :debug

    if role.running_proxy?
      leave_proxy
    else
      drain
    end

    leaving.each do |replica, version|
      execute *app(replica).stop(version: version), raise_on_non_zero_exit: false
    end
  end

  private
    def leave_proxy
      staying = @running - leaving.keys
      targets = Dash::Cli::App::RunningTargets.new(sshkit, role: role, host: host).container_ids(replicas: staying)
      execute *app.deploy(targets: targets.map { |id| id[0, SHORT_CONTAINER_ID_LENGTH] })
    end

    def drain
      return unless role.drain_signal

      leaving.each do |replica, version|
        execute *app(replica).signal(role.drain_signal, version: version), raise_on_non_zero_exit: false
      end

      await_drain
    end

    # A fixed wait for now. The autoscaling signal source will end it early once the
    # replicas report nothing in flight; this is the one place that has to change.
    def await_drain
      return unless role.drain_wait.positive?

      info "Waiting #{role.drain_wait}s for #{role} replicas #{leaving.keys.join(", ")} on #{host} to drain..."
      sleep role.drain_wait
    end

    def app(replica = 1)
      DASH.app(role: role, host: host, replica: replica)
    end
end
