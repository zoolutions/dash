class Dash::Commands::App < Dash::Commands::Base
  include Assets, Containers, ErrorPages, Execution, Images, Logging, Proxy

  ACTIVE_DOCKER_STATUSES = [ :running, :restarting ]

  # Separates the two answers #boot_state and #stale_state return. A container id is hex
  # and a version is a name suffix, so neither can produce this line on its own.
  BOOT_STATE_SEPARATOR = SECTION_SEPARATOR

  # Printed in place of the running containers when docker could not list them, so a boot
  # can tell "nothing runs" from "could not ask" - the chain's `;` hides the exit status.
  ACTIVE_CONTAINERS_UNREADABLE = "--unreadable--"

  # The two halves of a #boot_state or #stale_state capture, raw. Callers decide what an
  # empty half means; the separator line itself is dropped.
  def self.split_state(output)
    output.to_s.partition(/^#{Regexp.escape(BOOT_STATE_SEPARATOR)}$/).values_at(0, 2)
  end

  # Every segment of a #boot_states capture, raw, in the order they were asked.
  def self.split_states(output)
    output.to_s.split(/^#{Regexp.escape(BOOT_STATE_SEPARATOR)}$/, -1)
  end

  attr_reader :role, :host, :replica

  # `replica` is the slot this instance reads and writes. Slot 1 is the container the role
  # always had, so a role without `replicas:` is only ever slot 1 and its commands are
  # exactly what they were before replicas existed.
  def initialize(config, role: nil, host: nil, replica: 1)
    super(config)
    @role = role
    @host = host
    @replica = replica
  end

  def container_name(version = nil)
    role.replica_name(replica, version)
  end

  # The same role and host, another slot.
  def for_replica(replica)
    self.class.new(config, role: role, host: host, replica: replica)
  end

  def run(hostname: nil)
    docker :run,
      "--detach",
      "--restart", role.restart_policy,
      "--name", container_name,
      "--network", "dash",
      *([ "--hostname", hostname ] if hostname),
      "--env", "KAMAL_CONTAINER_NAME=\"#{container_name}\"",
      "--env", "KAMAL_VERSION=\"#{config.version}\"",
      "--env", "KAMAL_HOST=\"#{host}\"",
      *([ "--env", "KAMAL_DESTINATION=\"#{config.destination}\"" ] if config.destination),
      *([ "--env", "DASH_REPLICA=\"#{replica}\"" ] if slotted?),
      *role.env_args(host),
      *role.logging_args,
      *config.volume_args,
      *role.asset_volume_args,
      *role.label_args,
      *(argumentize("--label", { "replica" => replica }) if slotted?),
      *role.option_args,
      *role.healthcheck_args,
      config.absolute_image,
      role.cmd
  end

  def start
    docker :start, container_name
  end

  def status(version:)
    pipe container_id_for_version(version), xargs(docker(:inspect, "--format", DOCKER_HEALTH_STATUS_FORMAT))
  end

  # The `healthcheck: exec:` probe, run from the deploy host against the container that is
  # booting. Single-quoted by #shell, so the command expands inside the container rather
  # than in the deploy host's shell. Non-zero exit means not ready.
  def health_probe(version:)
    docker :exec, container_name(version), *shell([ role.healthcheck.exec ])
  end

  # Waits on the host for the container to reach a status the poller accepts, so a boot
  # pays one round trip for the wait however long the container takes to come up - the
  # client-side poll paid one per attempt. Prints the status it stopped on to stdout: the
  # moment it sees one of READY_STATUSES, or the last one it saw when the deadline passes.
  # Progress goes to stderr once a second in between. Waiting through every other status is
  # deliberate: docker reports a container `unhealthy` after three failed probes, which for
  # an app slower than that is a state it recovers from.
  #
  # Reaching the deadline exits 0, because it is an answer - the poller phrases it. Only a
  # status that could not be read at all exits non-zero, which is a broken command and
  # SSHKit's to raise, exactly as it was when the read was a round trip of its own.
  def wait_for_ready(version:, timeout:)
    shell [
      "started=$(date +%s);",
      "while true; do",
      *readiness_probe(version: version),
      "case \"$status\" in #{READY_STATUSES.join("|")}) echo \"$status\"; exit 0;; esac;",
      "elapsed=$(( $(date +%s) - started ));",
      "if [ \"$elapsed\" -ge #{timeout.to_i} ]; then echo \"$status\"; exit 0; fi;",
      "echo \"#{READINESS_PROGRESS_PREFIX} $elapsed $(( #{timeout.to_i} - elapsed )) $status\" 1>&2;",
      "sleep 1;",
      "done"
    ]
  end

  def stop(version: nil)
    pipe \
      version ? container_id_for_version(version) : current_running_container_id,
      xargs(docker(:stop, *role.stop_args))
  end

  def info
    docker :ps, *container_filter_args(all_replicas: true)
  end

  # `docker kill --signal`: how a replica without the proxy is told to stop taking work
  # before it is stopped.
  def signal(signal, version:)
    pipe container_id_for_version(version), xargs(docker(:kill, "--signal=#{signal}"))
  end

  # Every running container of the role with docker's status line, for `dash scale status`.
  def replica_status
    active_containers_ps format: '"{{.Names}}\t{{.Status}}"'
  end

  # The names of every running container of the role, whatever its slot. A slot's version
  # and whether it counts as running both come out of the name, so this is all a boot needs
  # to know how many replicas a host runs.
  def active_containers
    active_containers_ps format: '"{{.Names}}"'
  end


  def current_running_container_id
    current_running_container(format: "--quiet")
  end

  def container_id_for_version(version, only_running: false)
    container_id_for(container_name: container_name_pattern(version), only_running: only_running)
  end

  def current_running_version
    pipe \
      current_running_container(format: "--format '{{.Names}}'"),
      extract_version_from_name
  end

  # Everything a boot needs to know about a host before it starts anything: whether a
  # container for the version being deployed already exists (so it can be renamed out of
  # the way) and which version is running now (so it can be stopped once the new one is
  # live). Two questions, one round trip, answers split on BOOT_STATE_SEPARATOR.
  #
  # Chained with `;` rather than `&&`: an empty answer to either is a normal result, not
  # a failure, and the second question must be asked whatever the first one said.
  def boot_state(version)
    chain \
      container_id_for_version(version),
      [ :echo, BOOT_STATE_SEPARATOR ],
      current_running_version
  end

  # Everything the stale check needs from a host: every version of the role that has a
  # container, and the version running now - the difference is what is stale. Same shape
  # as #boot_state, same separator, same reason for `;` over `&&`.
  # #boot_state for the whole role on this host, still one round trip: slot 1's answers,
  # then every running container of the role (which carries each other slot's version and
  # the replica count), then whether slots 2..max already hold the version being deployed.
  # A role without replicas asks for the running containers too, so a deploy after
  # `replicas` was lowered still finds the slots it has to stop.
  def boot_states(version)
    clashes = role.replica_numbers.drop(1).flat_map do |replica|
      [ [ :echo, BOOT_STATE_SEPARATOR ], for_replica(replica).container_id_for_version(version) ]
    end

    chain \
      boot_state(version),
      [ :echo, BOOT_STATE_SEPARATOR ],
      [ *active_containers, "||", :echo, ACTIVE_CONTAINERS_UNREADABLE ],
      *clashes
  end

  def stale_state
    chain \
      list_versions,
      [ :echo, BOOT_STATE_SEPARATOR ],
      current_running_version
  end

  def list_versions(*docker_args, statuses: nil)
    pipe \
      docker(:ps, *container_filter_args(statuses: statuses), *docker_args, "--format", '"{{.Names}}"'),
      extract_version_from_name
  end

  def ensure_env_directory
    make_directory role.env_directory
  end

  private
    # The one `docker ps` both #active_containers and #replica_status ask: every running
    # container of the role, whatever its slot.
    def active_containers_ps(format:)
      docker :ps, *container_filter_args(statuses: ACTIVE_DOCKER_STATUSES, all_replicas: true), "--format", format
    end

    # The same two readiness sources #status and #health_probe cover, read into `$status`
    # so the loop around them is the same either way. They differ in what a non-zero exit
    # means. A probe that exits non-zero IS the answer "not ready", so its output is
    # discarded and the loop goes on; an inspect that produced no answer at all - docker is
    # unreachable, or the container is gone - takes the whole command down with it, with
    # docker's complaint on stderr for SSHKit to put in the exception.
    #
    # An empty status is checked as well as the exit code, because the exit code alone is
    # not portable: the read is a pipeline, so its status is xargs', and a `docker container
    # ls` that failed pipes nothing. GNU xargs then runs `docker inspect` with no container
    # and exits 123, but BSD and BusyBox xargs skip the utility entirely and exit 0. Both
    # leave `$status` empty, and empty is not something a working `docker inspect --format`
    # can print.
    def readiness_probe(version:)
      if role.healthcheck&.exec?
        [ "if", *health_probe(version: version), ">/dev/null 2>&1;", "then status=healthy;", "else status=\"#{EXEC_PROBE_FAILED}\";", "fi;" ]
      else
        [ "status=#{substitute(*status(version: version))} || exit $?;",
          "if [ -z \"$status\" ]; then echo \"could not read the status of #{container_name(version)}\" 1>&2; exit 1; fi;" ]
      end
    end

    def latest_image_id
      docker :image, :ls, *argumentize("--filter", "reference=#{config.latest_image}"), "--format", "'{{.ID}}'"
    end

    def current_running_container(format:)
      pipe \
        shell(chain(latest_image_container(format: format), latest_container(format: format))),
        [ :head, "-1" ]
    end

    def latest_image_container(format:)
      latest_container format: format, filters: [ "ancestor=$(#{latest_image_id.join(" ")})" ]
    end

    def latest_container(format:, filters: nil)
      docker :ps, "--latest", *format, *container_filter_args(statuses: ACTIVE_DOCKER_STATUSES), argumentize("--filter", filters)
    end

    def container_filter_args(statuses: nil, all_replicas: false)
      argumentize "--filter", container_filters(statuses: statuses, all_replicas: all_replicas)
    end

    def image_filter_args
      argumentize "--filter", image_filters
    end

    def extract_version_from_name
      # Extract SHA from "service-role-dest-SHA"
      %(while read line; do echo ${line##{role.replica_prefix(replica)}-}; done)
    end

    # The exact-name lookup for this slot's container of a version. Slot 1 keeps the name as
    # it always was; slot n escapes its prefix (see Role#replica_name_pattern).
    def container_name_pattern(version)
      replica > 1 ? "#{role.replica_name_pattern(replica)}-#{version}" : container_name(version)
    end

    def slotted?
      role.present? && role.replica_scoped?(replica)
    end

    def container_filters(statuses: nil, all_replicas: false)
      [ "label=service=#{config.service}" ].tap do |filters|
        filters << "label=destination=#{config.destination}"
        filters << "label=role=#{role}" if role
        filters << role.replica_name_filter(replica) if slotted? && !all_replicas
        statuses&.each do |status|
          filters << "status=#{status}"
        end
      end
    end

    def image_filters
      [ "label=service=#{config.service}" ]
    end
end
