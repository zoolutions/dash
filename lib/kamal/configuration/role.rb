class Kamal::Configuration::Role
  include Kamal::Configuration::Validation

  delegate :argumentize, :optionize, to: Kamal::Utils

  attr_reader :name, :config, :specialized_env, :specialized_logging, :specialized_proxy, :healthcheck

  alias to_s name

  def initialize(name, config:)
    @name, @config = name.inquiry, config
    validate! \
      role_config,
      example: validation_yml["servers"]["workers"],
      context: "servers/#{name}",
      with: Kamal::Configuration::Validator::Role

    @specialized_env = Kamal::Configuration::Env.new \
      config: specializations.fetch("env", {}),
      secrets: config.secrets,
      context: "servers/#{name}/env"

    @specialized_logging = Kamal::Configuration::Logging.new \
      logging_config: specializations.fetch("logging", {}),
      context: "servers/#{name}/logging"

    # `healthcheck: false` is an opt-out, not a healthcheck — it leaves @healthcheck nil.
    if healthcheck_config = specializations["healthcheck"]
      @healthcheck = Kamal::Configuration::Role::Healthcheck.new \
        healthcheck_config: healthcheck_config,
        context: "servers/#{name}/healthcheck"
    end

    initialize_specialized_proxy
  end

  def primary_host
    hosts.first
  end

  def hosts
    tagged_hosts.keys
  end

  def env_tags(host)
    tagged_hosts.fetch(host).collect { |tag| config.env_tag(tag) }.compact
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
  # one-shot `kamal app exec` containers, which must not inherit a service healthcheck.
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
  # before Kamal::Configuration#initialize has finished assigning its own collaborators.
  def boot
    return @boot if defined?(@boot)

    @boot =
      if (boot_config = specializations["boot"])
        Kamal::Configuration::Boot.new \
          config: config, boot_config: boot_config, host_count: hosts.count, context: "servers/#{name}/boot"
      end
  end

  def boot_runner_options
    boot&.runner_options || {}
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
  # the whole gate.
  def readiness_source
    if running_proxy?
      :proxy
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
      [ "kamal-proxy health check", proxy.healthcheck_path ].compact.join(" ")
    when :healthcheck
      healthcheck.port ? "healthcheck #{healthcheck.path}:#{healthcheck.port}" : "healthcheck (custom cmd)"
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
    # When deploying with the proxy, kamal-proxy will drain request before returning so we don't need to wait.
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
    [ container_prefix, version || config.version ].compact.join("-")
  end

  def container_prefix
    [ config.service, name, config.destination ].compact.join("-")
  end


  def asset_path
    asset_path_config&.dig(0)
  end

  def assets?
    asset_path.present? && running_proxy?
  end

  def asset_volume(version = config.version)
    if assets?
      Kamal::Configuration::Volume.new \
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
    if running_proxy? && proxy.ssl? && hosts.size > 1 && !proxy.loadbalancer.present? && !proxy.custom_ssl_certificate?
      raise Kamal::ConfigurationError, "SSL is only supported on a single server unless you provide custom certificates or configure a loadbalancer, found #{hosts.size} servers for role #{name}"
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

        @specialized_proxy = Kamal::Configuration::Proxy.new \
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
