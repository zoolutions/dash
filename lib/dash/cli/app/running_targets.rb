# The dash-proxy targets of one role on one host: the running container of every slot, in
# slot order. A role without replicas has one slot, so this asks exactly what re-registering
# a single container always asked.
class Dash::Cli::App::RunningTargets
  attr_reader :sshkit, :role, :host
  delegate :capture_with_info, to: :sshkit

  def initialize(sshkit, role:, host:)
    @sshkit = sshkit
    @role = role
    @host = host
  end

  def container_ids(only_running: false, replicas: role.replica_numbers)
    replicas.filter_map do |replica|
      app = DASH.app(role: role, host: host, replica: replica)

      read = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false)

      if (version = Dash::Cli::App::SlotVersion.new(sshkit, app).resolve(read))
        capture_with_info(*app.container_id_for_version(version, only_running: only_running), raise_on_non_zero_exit: false).strip.presence
      end
    end
  end
end
