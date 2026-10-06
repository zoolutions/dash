module Dash::Commands::App::Containers
  # A container's `docker ps` JSON, a tab, then docker's own value of its `role` label. The
  # JSON's `Labels` is "k=v,k=v" with no escaping, so a comma in another label's value could
  # pass for a role there; `.Label "role"` cannot be faked that way. JSON never holds a raw tab.
  PS_WITH_ROLE_FORMAT = %q('{{json .}}{{"\t"}}{{json (.Label "role")}}')

  DOCKER_HEALTH_LOG_FORMAT    = "'{{json .State.Health}}'"

  def list_containers
    docker :container, :ls, "--all", *container_filter_args
  end

  # Every container of the service in this destination, one per line in PS_WITH_ROLE_FORMAT.
  # Called without a role it covers every role and every replica slot on the host.
  def list_containers_json
    docker :container, :ls, "--all", *container_filter_args(all_replicas: true), "--format", PS_WITH_ROLE_FORMAT
  end

  # The running containers in PS_WITH_ROLE_FORMAT, then the separator,
  # then their `docker stats`. `xargs -r` matters: `docker stats` given no container
  # reports every container on the host, other apps' included. A docker ps that fails
  # prints ACTIVE_CONTAINERS_UNREADABLE, since the chain's `;` hides its exit status and
  # "could not ask" would otherwise read as "nothing runs".
  def stats_json
    filters = container_filter_args(statuses: Dash::Commands::App::ACTIVE_DOCKER_STATUSES, all_replicas: true)

    chain \
      [ *docker(:ps, *filters, "--format", PS_WITH_ROLE_FORMAT), "||", :echo, Dash::Commands::App::ACTIVE_CONTAINERS_UNREADABLE ],
      [ :echo, Dash::Commands::Base::SECTION_SEPARATOR ],
      pipe(docker(:ps, "--quiet", *filters), [ :xargs, "-r", :docker, :stats, "--no-stream", "--format", "'{{json .}}'", "||", :echo, Dash::Diagnostics::ContainerStats::STATS_UNREADABLE ])
  end

  def list_container_names
    [ *list_containers, "--format", "'{{ .Names }}'" ]
  end

  def remove_container(version:)
    pipe \
      container_id_for(container_name: container_name_pattern(version)),
      xargs(docker(:container, :rm))
  end

  def rename_container(version:, new_version:)
    docker :rename, container_name(version), container_name(new_version)
  end

  def remove_containers
    docker :container, :prune, "--force", *container_filter_args(all_replicas: true)
  end

  def container_health_log(version:)
    pipe \
      container_id_for(container_name: container_name_pattern(version)),
      xargs(docker(:inspect, "--format", DOCKER_HEALTH_LOG_FORMAT))
  end
end
