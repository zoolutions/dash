module Dash::Commands::App::Containers
  DOCKER_HEALTH_LOG_FORMAT    = "'{{json .State.Health}}'"

  def list_containers
    docker :container, :ls, "--all", *container_filter_args
  end

  # Every container of the service in this destination, one `docker ps` JSON object per
  # line. Called without a role it covers every role and every replica slot on the host.
  def list_containers_json
    docker :container, :ls, "--all", *container_filter_args(all_replicas: true), "--format", "'{{json .}}'"
  end

  # The running containers' `docker ps` JSON (for their role labels), then the separator,
  # then their `docker stats`. `xargs -r` matters: `docker stats` given no container
  # reports every container on the host, other apps' included.
  def stats_json
    filters = container_filter_args(statuses: Dash::Commands::App::ACTIVE_DOCKER_STATUSES, all_replicas: true)

    chain \
      docker(:ps, *filters, "--format", "'{{json .}}'"),
      [ :echo, Dash::Commands::App::BOOT_STATE_SEPARATOR ],
      pipe(docker(:ps, "--quiet", *filters), [ :xargs, "-r", :docker, :stats, "--no-stream", "--format", "'{{json .}}'" ])
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
