# The dash-proxy targets of one role on one host: the running container of every slot, in
# slot order. A role without replicas has one slot, so this asks what re-registering a
# single container always asked, plus which slots run at all.
class Dash::Cli::App::RunningTargets
  attr_reader :sshkit, :role, :host
  delegate :capture_with_info, to: :sshkit

  def initialize(sshkit, role:, host:)
    @sshkit = sshkit
    @role = role
    @host = host
  end

  def container_ids(only_running: false, replicas: self.replicas)
    replicas.filter_map do |replica|
      app = DASH.app(role: role, host: host, replica: replica)

      read = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false)

      if (version = Dash::Cli::App::SlotVersion.new(sshkit, app).resolve(read))
        capture_with_info(*app.container_id_for_version(version, only_running: only_running), raise_on_non_zero_exit: false).strip.presence
      end
    end
  end

  # The configured slots, plus any slot still running above them - a lowered max, or a
  # role whose `replicas` went away - until the next deploy stops it.
  def replicas
    @replicas ||= (role.replica_numbers | running_replicas).sort
  end

  private
    def running_replicas
      names = capture_with_info(*DASH.app(role: role, host: host).active_containers, raise_on_non_zero_exit: false).lines.map(&:strip)
      names.filter_map { |name| role.replica_from_name(name) }
    end
end
