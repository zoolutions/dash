class Dash::Configuration::Role
  include Dash::Configuration::Validation

  delegate :argumentize, :optionize, to: Dash::Utils

  attr_reader :name, :config, :specialized_env, :specialized_logging, :specialized_proxy, :healthcheck, :replicas, :drain, :scale

  delegate :numbers, to: :replicas, prefix: :replica
  delegate :signal, :wait, to: :drain, prefix: true

  alias to_s name

  def initialize(name, config:)
    @name, @config = name.inquiry, config
    validate! \
      role_config,
      example: validation_yml["servers"]["workers"],
      context: "servers/#{name}",
      with: Dash::Configuration::Validator::Role

    @specialized_env = Dash::Configuration::Env.new \
      config: specializations.fetch("env", {}),
      secrets: config.secrets,
      context: "servers/#{name}/env"

    @specialized_logging = Dash::Configuration::Logging.new \
      logging_config: specializations.fetch("logging", {}),
      context: "servers/#{name}/logging"

    # `healthcheck: false` is an opt-out, not a healthcheck — it leaves @healthcheck nil.
    if healthcheck_config = specializations["healthcheck"]
      @healthcheck = Dash::Configuration::Role::Healthcheck.new \
        healthcheck_config: healthcheck_config,
        context: "servers/#{name}/healthcheck"
    end

    @replicas = Dash::Configuration::Role::Replicas.new \
      replicas_config: specializations["replicas"],
      context: "servers/#{name}/replicas"

    @drain = Dash::Configuration::Role::Drain.new \
      drain_config: specializations["drain"],
      context: "servers/#{name}/drain"

    if (scale_config = specializations["scale"])
      @scale = Dash::Configuration::Role::Scale.new \
        scale_config: scale_config,
        baseline: baseline_hosts.size,
        context: "servers/#{name}/scale"
    end

    initialize_specialized_proxy

    if running_proxy? && drain.configured?
      raise Dash::ConfigurationError, "servers/#{name}/drain: a role behind dash-proxy is drained by the proxy, remove drain"
    end
  end

  def primary_host
    hosts.first
  end

  # Baseline hosts first, then the pool members the provider reports started. Every command
  # that reads a role's hosts sees the members; nothing else has to know about them.
  def hosts
    scaled? ? (baseline_hosts + active_members.map(&:host)).uniq : baseline_hosts
  end

  # The hosts deploy.yml lists for the role. Configuration-time checks read these and never
  # #hosts, which for a scaled role asks the autoscale provider.
  def baseline_hosts
    tagged_hosts.keys
  end

  def scaled?
    !scale.nil?
  end

  # Every pool member of the role, whatever its state.
  def members
    scaled? ? config.pool.members_for(self) : []
  end

  def active_members
    members.select(&:started?)
  end

  # `host` may be an SSHKit::Host - `on` hands those to its blocks.
  def member_host?(host)
    host = host.to_s
    !baseline_hosts.include?(host) && active_members.any? { |member| member.host == host }
  end

  # A member carries no tags: deploy.yml does not list it.
  def env_tags(host)
    tags = tagged_hosts.fetch(host) { member_host?(host) ? [] : raise(KeyError, "#{host} is not a host of role #{name}") }
    tags.collect { |tag| config.env_tag(tag) }.compact
  end

  # The role's own hosts carrying `tag` in deploy.yml. Accessory `tag:`/`tags:` resolution
  # comes through here rather than re-walking raw_config.servers, so it inherits
  # extract_hosts_from_config's handling of every legal role shape — bare list, `hosts:`
  # mapping, and the top-level `servers:` array.
  def hosts_with_tag(tag)
    tagged_hosts.select { |_host, tags| tags.include?(tag) }.keys
  end

  def cmd
    specializations["cmd"]
  end

  def option_args
    optionize docker_options.reject { |key, _| key.to_s == "restart" }
  end

  def restart_policy
    restart_policy_option || "unless-stopped"
  end

  def labels
    default_labels.merge(custom_labels)
  end

  def label_args
    argumentize "--label", labels
  end

  def logging_args
    logging.args
  end

  # Kept out of option_args on purpose: Commands::App::Execution splats those into
  # one-shot `dash app exec` containers, which must not inherit a service healthcheck.
  def healthcheck_args
    healthcheck&.args || []
  end

  def logging
    @logging ||= config.logging.merge(specialized_logging)
  end

  # nil unless the role paces its own hosts. Deliberately not falling back to the global
  # boot: that limit is already spent slicing the cross-role host list in
  # Cli::App#host_boot_groups, and handing it to the per-role runner as well would sleep
  # `boot.wait` a second time inside every group.
  #
  # Built on first read rather than in the initializer — Servers.new constructs every Role
  # before Dash::Configuration#initialize has finished assigning its own collaborators.
  def boot
    return @boot if defined?(@boot)

    @boot =
      if (boot_config = specializations["boot"])
        Dash::Configuration::Boot.new \
          config: config, boot_config: boot_config, context: "servers/#{name}/boot"
      end
  end

  # `hosts` is what on_roles is about to pace — `role.hosts & the run's hosts`, so
  # --roles/--hosts have already narrowed it. A percentage limit has to count that, not
  # the role's configured hosts.
  def boot_runner_options(hosts)
    boot&.runner_options_for(hosts) || {}
  end

  def proxy
    @proxy ||= specialized_proxy.merge(config.proxy) if running_proxy?
  end

  def running_proxy?
    @running_proxy
  end

  def ssl?
    running_proxy? && proxy.ssl?
  end

  # Where a deploy of this role actually waits for readiness before stopping the
  # old container. Without a proxy or a docker healthcheck, Healthcheck::Poller
  # only sees `.State.Status`, so staying `running` for the readiness delay is
  # the whole gate. `:healthcheck_exec` is the odd one out: the container declares no
  # docker healthcheck, the deploy host polls the probe itself.
  def readiness_source
    if running_proxy?
      :proxy
    elsif healthcheck&.exec?
      :healthcheck_exec
    elsif healthcheck
      :healthcheck
    elsif health_cmd_option?
      :docker_options
    else
      :none
    end
  end

  # One-line rendering of readiness_source, shared by the deploy banner and `kamal doctor`
  # so both name the same gate the same way.
  def readiness_description
    case readiness_source
    when :proxy
      [ "dash-proxy health check", proxy.healthcheck_path ].compact.join(" ")
    when :healthcheck
      healthcheck.port ? "healthcheck #{healthcheck.path}:#{healthcheck.port}" : "healthcheck (custom cmd)"
    when :healthcheck_exec
      "healthcheck exec probe (#{healthcheck.exec})"
    when :docker_options
      "docker healthcheck (options: health-cmd)"
    else
      "NONE (old container stops #{readiness_delay}s after boot)"
    end
  end

  # Whether the operator has made a readiness decision for this role at all — declared a
  # healthcheck, hand-rolled a health-cmd option, or accepted the gap with `healthcheck: false`.
  # Distinct from readiness_source, which reports what actually gates the deploy.
  def readiness_gated?
    healthcheck.present? || health_cmd_option? || healthcheck_disabled?
  end

  def stop_args
    # When deploying with the proxy, dash-proxy will drain request before returning so we don't need to wait.
    timeout = stop_timeout || (running_proxy? ? nil : config.drain_timeout)

    [ *argumentize("-t", timeout) ]
  end

  def stop_timeout
    specializations["stop_timeout"] || config.stop_timeout
  end

  # How long a role that has no healthcheck must merely keep running before the deploy
  # accepts it. Role-specialized so a role that legitimately opts out can be tuned
  # without slowing every other role down.
  def readiness_delay
    specializations["readiness_delay"] || config.readiness_delay
  end

  def env(host)
    @envs ||= {}
    @envs[host] ||= [ config.env, specialized_env, *env_tags(host).map(&:env) ].reduce(:merge)
  end

  def env_args(host)
    [ *env(host).clear_args, *argumentize("--env-file", secrets_path) ]
  end

  def env_directory
    File.join(config.env_directory, "roles")
  end

  def secrets_io(host)
    env(host).secrets_io
  end

  def secrets_path
    File.join(config.env_directory, "roles", "#{name}.env")
  end

  def asset_volume_args
    asset_volume&.docker_args
  end


  def primary?
    name == @config.primary_role_name
  end


  def container_name(version = nil)
    replica_name(1, version)
  end

  # Also the dash-proxy service name, which stays one per role whatever the replica count.
  def container_prefix
    replica_prefix(1)
  end

  # Replica 1 is the container the role always had, so its name never changed; replica n
  # puts the slot into the role segment, where a free-form version cannot reach it.
  def replica_prefix(replica)
    [ config.service, replica == 1 ? name : "#{name}.#{replica}", config.destination ].compact.join("-")
  end

  # Whether docker lookups for a slot need its name as well as the role labels: a scalable
  # role's slot 1 would otherwise see slot 2's containers. Slot 2 and up always do, even
  # after `replicas` was lowered to 1, so a deploy can still find and stop them.
  def replica_scoped?(replica)
    replica > 1 || replicas.scalable?
  end

  # The `--filter name=` value for a slot's containers. Docker matches it as a regular
  # expression, so a `.` in the slot or the destination has to be literal.
  def replica_name_filter(replica)
    "'name=^#{replica_name_pattern(replica)}-'"
  end

  # The slot's prefix as a docker name regex: slot n's `.` has to be literal, or
  # `^app-web.2-123$` would also match slot 1's container of a version named `2-123`.
  def replica_name_pattern(replica)
    replica_prefix(replica).gsub(/[.^$*+?()\[\]{}|\\]/) { |char| "\\#{char}" }
  end

  def replica_name(replica, version = nil)
    [ replica_prefix(replica), version || config.version ].compact.join("-")
  end

  # The slot a container of this role is, read from its name - nil when the name is not
  # one of this role's. The `role` label already excludes a sibling role whose name extends
  # this one, so callers only ever hand this names of this role's containers.
  def replica_from_name(container_name)
    if container_name.start_with?("#{replica_prefix(1)}-")
      1
    elsif (match = replica_name_regexp.match(container_name))
      match[1].to_i
    end
  end

  def version_from_name(container_name)
    if (replica = replica_from_name(container_name))
      container_name.delete_prefix("#{replica_prefix(replica)}-")
    end
  end

  def docker_option_keys
    docker_options.keys.map(&:to_s)
  end

  def docker_option_values(*keys)
    docker_options.select { |key, _| keys.include?(key.to_s) }.values.flatten
  end


  def asset_path
    asset_path_config&.dig(0)
  end

  def assets?
    asset_path.present? && running_proxy?
  end

  def asset_volume(version = config.version)
    if assets?
      Dash::Configuration::Volume.new \
        host_path: asset_volume_directory(version), container_path: asset_path, options: asset_path_options
    end
  end

  def asset_path_options
    asset_path_config&.dig(1)
  end

  def asset_extracted_directory(version = config.version)
    File.join config.assets_directory, "extracted", [ name, version ].join("-")
  end

  def asset_volume_directory(version = config.version)
    File.join config.assets_directory, "volumes", [ name, version ].join("-")
  end

  def ensure_one_host_for_ssl
    # Skip SSL validation when a loadbalancer is present or custom certificates are provided
    if running_proxy? && proxy.ssl? && baseline_hosts.size > 1 && !proxy.loadbalancer.present? && !proxy.custom_ssl_certificate?
      raise Dash::ConfigurationError, "SSL is only supported on a single server unless you provide custom certificates or configure a loadbalancer, found #{baseline_hosts.size} servers for role #{name}"
    end
  end

  private
    def initialize_specialized_proxy
      proxy_specializations = specializations["proxy"]

      if primary?
        # only false means no proxy for non-primary roles
        @running_proxy = proxy_specializations != false
      else
        # false and nil both mean no proxy for non-primary roles
        @running_proxy = !!proxy_specializations
      end

      if running_proxy?
        proxy_config = proxy_specializations == true || proxy_specializations.nil? ? {} : proxy_specializations

        @specialized_proxy = Dash::Configuration::Proxy.new \
          config: config,
          proxy_config: proxy_config,
          secrets: config.secrets,
          role_name: name,
          context: "servers/#{name}/proxy"
      end
    end

    def tagged_hosts
      {}.tap do |tagged_hosts|
        extract_hosts_from_config.map do |host_config|
          if host_config.is_a?(Hash)
            host, tags = host_config.first
            tagged_hosts[host] = Array(tags)
          elsif host_config.is_a?(String)
            tagged_hosts[host_config] = []
          end
        end
      end
    end

    def extract_hosts_from_config
      if config.raw_config.servers.is_a?(Array)
        config.raw_config.servers
      else
        servers = config.raw_config.servers[name]
        servers.is_a?(Array) ? servers : Array(servers["hosts"])
      end
    end

    def replica_name_regexp
      destination = "-#{Regexp.escape(config.destination)}" if config.destination
      /\A#{Regexp.escape(config.service)}-#{Regexp.escape(name)}\.(\d+)#{destination}-/
    end

    def default_labels
      { "service" => config.service, "role" => name, "destination" => config.destination }
    end

    def specializations
      @specializations ||= role_config.is_a?(Array) ? {} : role_config
    end

    def role_config
      @role_config ||= config.raw_config.servers.is_a?(Array) ? {} : config.raw_config.servers[name]
    end

    def docker_options
      specializations["options"] || {}
    end

    def restart_policy_option
      docker_options.find { |key, _| key.to_s == "restart" }&.last
    end

    def health_cmd_option?
      docker_options.any? { |key, _| key.to_s == "health-cmd" }
    end

    def healthcheck_disabled?
      specializations["healthcheck"] == false
    end

    def custom_labels
      Hash.new.tap do |labels|
        labels.merge!(config.labels) if config.labels.present?
        labels.merge!(specializations["labels"]) if specializations["labels"].present?
      end
    end

    def asset_path_config
      raw_path = specializations["asset_path"] || config.asset_path
      return nil unless raw_path.present?

      parts = raw_path.split(":", 2)
      [ parts[0], parts[1] ]
    end
end
