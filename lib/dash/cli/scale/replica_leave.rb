# Removes replica slots of one role on one host, gracefully. A web replica leaves the proxy
# pool first - the redeploy without it drains its in-flight requests - and only then stops.
# A worker replica is sent its drain signal and given its drain wait before `docker stop`,
# whose own timeout is the role's stop budget. A role with a Sidekiq signal ends the wait as
# soon as Sidekiq reports nothing busy in the leaving containers.
class Dash::Cli::Scale::ReplicaLeave
  SHORT_CONTAINER_ID_LENGTH = Dash::Cli::App::Boot::SHORT_CONTAINER_ID_LENGTH
  BUSY_POLL_INTERVAL = 2

  attr_reader :host, :role, :leaving, :sshkit
  delegate :execute, :capture_with_info, :info, to: :sshkit

  # What can say how many jobs a container is still working on: the role's signal, when its
  # source can (only Sidekiq). Nil for every other role.
  def self.busy_reader_for(role)
    return unless role.scaled? && role.scale.signal?

    Dash::Autoscale::Signal.for(role, Dash::Autoscale::Connections.shared).then { |reader| reader if reader.busy? }
  end

  # `leaving` is { replica => running version }; `running` is every slot running on the host.
  def initialize(host, role, leaving, sshkit, running:, busy_reader: self.class.busy_reader_for(role))
    @host = host
    @role = role
    @leaving = leaving
    @sshkit = sshkit
    @running = running
    @busy_reader = busy_reader
  end

  def run
    execute *DASH.auditor(role: role).record("Scaled in replicas #{leaving.keys.join(", ")}"), verbosity: :debug

    if role.running_proxy?
      leave_proxy
    else
      drain
    end

    # A stop that fails must fail the scale-in: the replica would still run while the
    # command reported the count reached.
    leaving.each do |replica, version|
      execute *app(replica).stop(version: version)
    end
  end

  private
    def leave_proxy
      staying = @running - leaving.keys
      targets = Dash::Cli::App::RunningTargets.new(sshkit, role: role, host: host).container_ids(replicas: staying)
      execute *app.deploy(targets: targets.map { |id| id[0, SHORT_CONTAINER_ID_LENGTH] })
    end

    # The signal is optional; the wait is not tied to it, so `drain: { wait: N }` alone
    # still gives a replica N seconds before `docker stop`. The hostnames are read first:
    # a container told to stop may not answer an inspect for long.
    def drain
      hostnames = leaving_hostnames if @busy_reader && role.drain_wait.positive?

      if role.drain_signal
        leaving.each do |replica, version|
          execute *app(replica).signal(role.drain_signal, version: version), raise_on_non_zero_exit: false
        end
      end

      await_drain(hostnames)
    end

    # The full drain wait, or - with the hostnames to ask about - until nothing is busy in
    # them, polling every BUSY_POLL_INTERVAL seconds. A busy count that cannot be read waits
    # out the rest of the drain.
    def await_drain(hostnames)
      return unless role.drain_wait.positive?

      info "Waiting up to #{role.drain_wait}s for #{role} replicas #{leaving.keys.join(", ")} on #{host} to drain..."
      return sleep(role.drain_wait) if hostnames.blank?

      deadline = monotonic + role.drain_wait
      loop do
        busy = busy_count(hostnames)
        return info("#{role} replicas #{leaving.keys.join(", ")} on #{host} have nothing busy") if busy&.zero?

        remaining = deadline - monotonic
        return unless remaining.positive?

        sleep(busy.nil? ? remaining : [ BUSY_POLL_INTERVAL, remaining ].min)
        return if busy.nil?
      end
    end

    def leaving_hostnames
      leaving.map { |replica, version| capture_with_info(*app(replica).container_hostname(version: version)).strip }.reject(&:empty?)
    rescue SSHKit::Command::Failed => e
      info "Could not read the hostnames of #{role} replicas #{leaving.keys.join(", ")} on #{host} (#{e.message}), so the drain waits its full #{role.drain_wait}s"
      nil
    end

    # Like a signal sample, a failed read never fails the scale-in: it only loses the early end.
    def busy_count(hostnames)
      @busy_reader.busy(hostnames)
    rescue StandardError => e
      info "Could not read what #{role} replicas #{leaving.keys.join(", ")} on #{host} are working on (#{e.class}: #{e.message}), so the drain waits out drain.wait"
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def app(replica = 1)
      DASH.app(role: role, host: host, replica: replica)
    end
end
