# The version one replica slot runs, from a `current_running_version` read that may have
# answered for another slot. A role without replicas reads slot 1 over the role labels alone,
# so while slots left over from when it had them still run, `--latest` can return one of
# theirs - an unstripped name like `app-web.2-123`. Taking that as slot 1's version would
# make the live container look stale, or drop it from the proxy targets. Only then is the
# role's running containers read, once more, to find the slot's own.
class Dash::Cli::App::SlotVersion
  attr_reader :sshkit, :app
  delegate :role, :replica, to: :app
  delegate :capture_with_info, to: :sshkit

  def initialize(sshkit, app)
    @sshkit = sshkit
    @app = app
  end

  def resolve(read)
    version = read.to_s.strip.presence
    return version unless foreign?(version)

    names = capture_with_info(*app.active_containers, raise_on_non_zero_exit: false).lines.map(&:strip)
    names.filter_map { |name| role.version_from_name(name) if role.replica_from_name(name) == replica }.first
  end

  # A listed "version" that is really another slot's whole container name.
  def foreign?(version)
    (owner = version && role.replica_from_name(version)) && owner != replica
  end
end
