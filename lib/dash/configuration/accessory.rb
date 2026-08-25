class Dash::Configuration::Accessory
  include Dash::Configuration::Validation

  DEFAULT_NETWORK = "kamal"

  delegate :argumentize, :optionize, to: Dash::Utils

  attr_reader :name, :env, :proxy, :registry

  def initialize(name, config:)
    @name, @config, @accessory_config = name.inquiry, config, config.raw_config["accessories"][name]

    validate! \
      accessory_config,
      example: validation_yml["accessories"]["mysql"],
      context: "accessories/#{name}",
      with: Dash::Configuration::Validator::Accessory

    ensure_valid_roles

    @env = initialize_env
    @proxy = initialize_proxy if running_proxy?
    @registry = initialize_registry if accessory_config["registry"].present?
  end

  def service_name
    accessory_config["service"] || "#{config.service}-#{name}"
  end

  def image
    [ registry&.server, accessory_config["image"] ].compact.join("/")
  end

  def hosts
    hosts_from_host || hosts_from_hosts || hosts_from_roles || hosts_from_tags
  end

  def port
    if port = accessory_config["port"]&.to_s
      port.include?(":") ? port : "#{port}:#{port}"
    end
  end

  def network_args
    argumentize "--network", network
  end

  def publish_args
    argumentize "--publish", port if port
  end

  def labels
    default_labels.merge(accessory_config["labels"] || {})
  end

  def label_args
    argumentize "--label", labels
  end

  def env_args
    [ *env.clear_args, *argumentize("--env-file", secrets_path) ]
  end

  def env_directory
    File.join(config.env_directory, "accessories")
  end

  def secrets_io
    env.secrets_io
  end

  def secrets_path
    File.join(config.env_directory, "accessories", "#{name}.env")
  end

  def files
    accessory_config["files"]&.to_h do |config|
      parse_path_config(config, default_mode: "755") do |local, remote|
        {
          key: expand_local_file(local),
          host_path: expand_remote_file(remote),
          container_path: remote
        }
      end
    end || {}
  end

  def directories
    accessory_config["directories"]&.to_h do |config|
      parse_path_config(config, default_mode: nil) do |local, remote|
        {
          key: expand_host_path(local),
          host_path: expand_host_path_for_volume(local),
          container_path: remote
        }
      end
    end || {}
  end

  def volume_args
    argumentize("--volume", specific_volumes) + (path_volumes(files) + path_volumes(directories)).flat_map(&:docker_args)
  end

  def option_args
    optionize docker_options.reject { |key, _| key.to_s == "restart" }
  end

  def restart_policy
    restart_policy_option || "unless-stopped"
  end

  def cmd
    accessory_config["cmd"]
  end

  def running_proxy?
    accessory_config["proxy"].present?
  end

  private
    attr_reader :config, :accessory_config

    def initialize_env
      Dash::Configuration::Env.new \
        config: accessory_config.fetch("env", {}),
        secrets: config.secrets,
        context: "accessories/#{name}/env"
    end

    # The load balancer fans the app's own service out to role targets only
    # (see Dash::Cli::Proxy#loadbalancer), so an accessory is never behind it
    # and must keep the host/TLS it registers with kamal-proxy directly.
    def initialize_proxy
      Dash::Configuration::Proxy.new \
        config: config,
        proxy_config: accessory_config["proxy"],
        context: "accessories/#{name}/proxy",
        secrets: config.secrets,
        load_balanced: false
    end

    def initialize_registry
      Dash::Configuration::Registry.new \
        config: accessory_config,
        secrets: config.secrets,
        context: "accessories/#{name}/registry"
    end

    def default_labels
      { "service" => service_name }
    end

    def expand_local_file(local_file)
      if local_file.end_with?("erb")
        with_env_loaded { read_dynamic_file(local_file) }
      else
        Pathname.new(File.expand_path(local_file)).to_s
      end
    end

    def with_env_loaded
      env.to_h.each { |k, v| ENV[k] = v }
      yield
    ensure
      env.to_h.each { |k, v| ENV.delete(k) }
    end

    def read_dynamic_file(local_file)
      StringIO.new(ERB.new(File.read(local_file)).result)
    end

    def expand_remote_file(remote_file)
      service_name + remote_file
    end

    def specific_volumes
      accessory_config["volumes"] || []
    end

    def docker_options
      accessory_config["options"] || {}
    end

    def restart_policy_option
      docker_options.find { |key, _| key.to_s == "restart" }&.last
    end

    def path_volumes(paths)
      paths.map do |local, config|
        Dash::Configuration::Volume.new \
          host_path: config[:host_path],
          container_path: config[:container_path],
          options: config[:options]
      end
    end

    def parse_path_config(config, default_mode:)
      if config.is_a?(Hash)
        local, remote = config["local"], config["remote"]
        expanded = yield(local, remote)
        [
          expanded[:key],
          expanded.except(:key).merge(
            options: config["options"],
            mode: config["mode"] || default_mode,
            owner: config["owner"]
          )
        ]
      else
        local, remote, options = config.split(":", 3)
        expanded = yield(local, remote)
        [
          expanded[:key],
          expanded.except(:key).merge(
            options: options,
            mode: default_mode,
            owner: nil
          )
        ]
      end
    end

    def expand_host_path(host_path)
      absolute_path?(host_path) ? host_path : File.join(service_data_directory, host_path)
    end

    def expand_host_path_for_volume(host_path)
      absolute_path?(host_path) ? host_path : File.join(service_name, host_path)
    end

    def absolute_path?(path)
      Pathname.new(path).absolute?
    end

    def service_data_directory
      "$PWD/#{service_name}"
    end

    def hosts_from_host
      [ accessory_config["host"] ] if accessory_config.key?("host")
    end

    def hosts_from_hosts
      accessory_config["hosts"] if accessory_config.key?("hosts")
    end

    def hosts_from_roles
      if accessory_config.key?("role")
       config.role(accessory_config["role"])&.hosts
      elsif accessory_config.key?("roles")
        accessory_config["roles"].flat_map { |role| config.role(role)&.hosts }
      end
    end

    def hosts_from_tags
      if accessory_config.key?("tag")
        extract_hosts_from_config_with_tag(accessory_config["tag"])
      elsif accessory_config.key?("tags")
        accessory_config["tags"].flat_map { |tag| extract_hosts_from_config_with_tag(tag) }
      end
    end

    # Ask each role for its own tagged hosts instead of re-parsing raw_config.servers here:
    # a role may be written as a bare list or as a `hosts:` mapping, and Role already reads
    # both. A second parser with a shape assumption dropped tagged hosts silently.
    def extract_hosts_from_config_with_tag(tag)
      config.roles.flat_map { |role| role.hosts_with_tag(tag) }
    end

    def network
      accessory_config["network"] || DEFAULT_NETWORK
    end

    def ensure_valid_roles
      if accessory_config["roles"] && (missing_roles = accessory_config["roles"] - config.roles.map(&:name)).any?
        raise Dash::ConfigurationError, "accessories/#{name}: unknown roles #{missing_roles.join(", ")}"
      elsif accessory_config["role"] && !config.role(accessory_config["role"])
        raise Dash::ConfigurationError, "accessories/#{name}: unknown role #{accessory_config["role"]}"
      end
    end
end
