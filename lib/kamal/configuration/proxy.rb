class Kamal::Configuration::Proxy
  include Kamal::Configuration::Validation

  DEFAULT_LOG_REQUEST_HEADERS = [ "Cache-Control", "Last-Modified", "User-Agent" ]
  CONTAINER_NAME = "kamal-proxy"
  LOADBALANCER_CONTAINER_NAME = "kamal-loadbalancer"

  delegate :argumentize, :optionize, to: Kamal::Utils

  attr_reader :config, :proxy_config, :role_name, :run, :secrets

  # `load_balanced: false` marks a registration the fork's load balancer can
  # never front - accessories, whose targets it does not collect. Such a proxy
  # keeps its own host/TLS/basic-auth instead of deferring them to the edge.
  def initialize(config:, proxy_config:, role_name: nil, secrets:, context: "proxy", load_balanced: true)
    @config = config
    @proxy_config = proxy_config
    @proxy_config = {} if @proxy_config.nil?
    @role_name = role_name
    @load_balanced = load_balanced
    @secrets = secrets
    validate! @proxy_config, with: Kamal::Configuration::Validator::Proxy, context: context
    @run = Kamal::Configuration::Proxy::Run.new(config, run_config: @proxy_config["run"], context: "#{context}/run") if @proxy_config && @proxy_config["run"].present?
  end

  def app_port
    proxy_config.fetch("app_port", 80)
  end

  def ssl?
    proxy_config.fetch("ssl", false)
  end

  def hosts
    proxy_config["hosts"] || proxy_config["host"]&.split(",") || []
  end

  def loadbalancer
    proxy_config["loadbalancer"]
  end

  # Root-level `proxy` setting only; ignored inside role-specific proxy blocks.
  def reboot_on_deploy?
    proxy_config.fetch("reboot_on_deploy", true)
  end

  def load_balancing?
    effective_loadbalancer.present?
  end

  def load_balanced?
    @load_balanced
  end

  def effective_loadbalancer
    return nil unless load_balanced?
    return false if loadbalancer == false
    return primary_role_first_host if loadbalancer == true
    return loadbalancer if loadbalancer.present?
    return primary_role_first_host if config.primary_role && Array(config.primary_role.hosts).size > 1

    nil
  end

  def loadbalancer_on_proxy_host?
    load_balancing? && config.proxy_hosts.include?(effective_loadbalancer)
  end

  def custom_ssl_certificate?
    ssl = proxy_config["ssl"]
    return false unless ssl.is_a?(Hash)
    ssl["certificate_pem"].present? && ssl["private_key_pem"].present?
  end

  def certificate_pem_content
    ssl = proxy_config["ssl"]
    return nil unless ssl.is_a?(Hash)
    secrets[ssl["certificate_pem"]]
  end

  def private_key_pem_content
    ssl = proxy_config["ssl"]
    return nil unless ssl.is_a?(Hash)
    secrets[ssl["private_key_pem"]]
  end

  def host_tls_cert
    tls_path(config.proxy_boot.tls_directory, "cert.pem")
  end

  def host_tls_key
    tls_path(config.proxy_boot.tls_directory, "key.pem")
  end

  def container_tls_cert
    tls_path(config.proxy_boot.tls_container_directory, "cert.pem")
  end

  def container_tls_key
    tls_path(config.proxy_boot.tls_container_directory, "key.pem") if custom_ssl_certificate?
  end

  def path_prefixes
    proxy_config["path_prefixes"] || proxy_config["path_prefix"]&.split(",") || []
  end

  # Nil when unset: the default lives in kamal-proxy, not here.
  def healthcheck_path
    proxy_config.dig("healthcheck", "path")
  end

  def deploy_options
    opts = {
      host: hosts,
      tls: ssl? ? true : nil,
      "tls-staging": proxy_config["ssl_staging"] ? true : nil,
      "tls-certificate-path": container_tls_cert,
      "tls-private-key-path": container_tls_key,
      "deploy-timeout": seconds_duration(config.deploy_timeout),
      "drain-timeout": seconds_duration(config.drain_timeout),
      "health-check-interval": seconds_duration(proxy_config.dig("healthcheck", "interval")),
      "health-check-timeout": seconds_duration(proxy_config.dig("healthcheck", "timeout")),
      "health-check-path": healthcheck_path,
      "health-check-port": proxy_config.dig("healthcheck", "port"),
      "health-check-host": proxy_config.dig("healthcheck", "host"),
      "target-timeout": seconds_duration(proxy_config["response_timeout"]),
      "read-target": proxy_config["read_targets"].presence,
      "read-target-websockets": proxy_config["read_target_websockets"] ? true : nil,
      "writer-affinity-timeout": seconds_duration(proxy_config["writer_affinity_timeout"]),
      "path-timeout": path_timeout_args,
      "buffer-requests": proxy_config.fetch("buffering", { "requests": true }).fetch("requests", true),
      "buffer-responses": proxy_config.fetch("buffering", { "responses": true }).fetch("responses", true),
      "buffer-memory": proxy_config.dig("buffering", "memory"),
      "max-request-body": proxy_config.dig("buffering", "max_request_body"),
      "max-response-body": proxy_config.dig("buffering", "max_response_body"),
      "path-prefix": path_prefixes,
      "strip-path-prefix": proxy_config.dig("strip_path_prefix"),
      "forward-headers": proxy_config.dig("forward_headers"),
      "tls-redirect": proxy_config.dig("ssl_redirect"),
      "basic-auth": basic_auth_credential,
      "log-request-header": proxy_config.dig("logging", "request_headers") || DEFAULT_LOG_REQUEST_HEADERS,
      "log-response-header": proxy_config.dig("logging", "response_headers"),
      "error-pages": error_pages
    }.merge(tls_domains_options).compact

    if load_balancing?
      opts.delete(:host)
      opts.delete(:tls)
      tls_domains_options.each_key { |key| opts.delete(key) }
      # kamal-proxy deletes the Authorization header once a service enforces
      # basic auth, so the load balancer would authenticate the client and then
      # forward a credential-less request that this proxy would 401. Credentials
      # belong at the edge only.
      opts.delete(:"basic-auth")
    end

    opts
  end

  def deploy_command_args(target:)
    optionize ({ target: "#{target}:#{app_port}" }).merge(deploy_options), with: "="
  end

  # kamal-proxy rollout deploy only accepts the target and the timeouts - the service already
  # exists, so it keeps the host, TLS, buffering and logging options of the live deploy.
  def rollout_deploy_options
    {
      "deploy-timeout": seconds_duration(config.deploy_timeout),
      "drain-timeout": seconds_duration(config.drain_timeout)
    }.compact
  end

  def rollout_deploy_command_args(target:)
    optionize ({ target: "#{target}:#{app_port}" }).merge(rollout_deploy_options), with: "="
  end

  def rollout_set_command_args(percent: nil, list: nil)
    optionize({ percent: percent, list: list }.compact, with: "=")
  end

  def stop_options(drain_timeout: nil, message: nil)
    {
      "drain-timeout": seconds_duration(drain_timeout),
      message: message
    }.compact
  end

  def stop_command_args(**options)
    optionize stop_options(**options), with: "="
  end

  def merge(other)
    self.class.new config: config, proxy_config: other.proxy_config.deep_merge(proxy_config), role_name: role_name, secrets: secrets, load_balanced: load_balanced?
  end

  private
    def primary_role_first_host
      config.primary_role&.hosts&.first
    end

    # Flags for kamal-proxy's dynamic domain source (runtime TLS hostnames).
    # TLS terminates wherever these flags land, so like host/tls they are
    # stripped from the per-app deploy when load balancing and re-added by
    # Kamal::Configuration::Loadbalancer#deploy_options.
    def tls_domains_options
      {
        "tls-domains-source": proxy_config.dig("tls_domains", "source"),
        "tls-domains-interval": seconds_duration(proxy_config.dig("tls_domains", "interval")),
        "tls-domains-batch-size": proxy_config.dig("tls_domains", "batch_size")
      }.compact
    end

    def tls_path(directory, filename)
      File.join([ directory, role_name, filename ].compact) if custom_ssl_certificate?
    end

    def seconds_duration(value)
      value ? "#{value}s" : nil
    end

    # kamal-proxy takes the credential as <username>:<password> and cuts at the
    # first colon, so a password may contain colons but a username may not (the
    # validator enforces that). The password is read from .kamal/secrets when
    # password_secret names it, so it need not live in deploy.yml.
    def basic_auth_credential
      basic_auth = proxy_config["basic_auth"]
      return nil unless basic_auth.is_a?(Hash)

      password =
        if (secret_name = basic_auth["password_secret"]).present?
          secrets[secret_name]
        else
          basic_auth["password"]
        end

      # The validator guarantees a password was configured, so a blank one here
      # means the named secret resolved empty. Fail rather than drop the flag —
      # silently deploying an unprotected service is the worse outcome.
      if password.blank?
        raise Kamal::ConfigurationError, "proxy/basic_auth: password_secret '#{secret_name}' is empty"
      end

      "#{basic_auth["username"]}:#{password}"
    end

    def path_timeout_args
      if (timeouts = proxy_config["path_timeouts"]).present?
        timeouts.map do |prefix, duration|
          duration = seconds_duration(duration) if duration.is_a?(Numeric)
          "#{prefix}=#{duration}"
        end
      end
    end

    def error_pages
      File.join config.proxy_boot.error_pages_container_directory, config.version if config.error_pages_path
    end
end
