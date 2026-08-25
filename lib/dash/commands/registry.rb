class Dash::Commands::Registry < Dash::Commands::Base
  LOCAL_CONTAINER_NAME = "dash-docker-registry"
  LEGACY_LOCAL_CONTAINER_NAME = "kamal-docker-registry"

  def login(registry_config: nil)
    registry_config ||= config.registry

    return if registry_config.local?

    docker :login,
      registry_config.server,
      "-u", sensitive(Dash::Utils.escape_shell_value(registry_config.username)),
      "-p", sensitive(Dash::Utils.escape_shell_value(registry_config.password))
  end

  def logout(registry_config: nil)
    registry_config ||= config.registry

    docker :logout, registry_config.server
  end

  def setup(registry_config: nil)
    registry_config ||= config.registry

    combine \
      docker(:start, LOCAL_CONTAINER_NAME),
      docker(:run, "--detach", "-p", "127.0.0.1:#{registry_config.local_port}:5000", "--name", LOCAL_CONTAINER_NAME, "registry:3"),
      by: "||"
  end

  # The legacy container is torn down alongside the current one so an operator's
  # laptop doesn't keep a stray kamal-docker-registry holding the local port
  # after upgrading. Dash::Cli::Registry#remove already runs this with
  # raise_on_non_zero_exit: false, so a missing container of either name is fine.
  def remove
    chain \
      combine(docker(:stop, LOCAL_CONTAINER_NAME), docker(:rm, LOCAL_CONTAINER_NAME)),
      combine(docker(:stop, LEGACY_LOCAL_CONTAINER_NAME), docker(:rm, LEGACY_LOCAL_CONTAINER_NAME))
  end

  def local?
    config.registry.local?
  end
end
