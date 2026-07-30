class Kamal::Configuration::Proxy
  include Kamal::Configuration::Validation

  DEFAULT_LOG_REQUEST_HEADERS = [ "Cache-Control", "Last-Modified", "User-Agent" ]
  CONTAINER_NAME = "kamal-proxy"
  LOADBALANCER_CONTAINER_NAME = "kamal-loadbalancer"
  CLIENT_CA_FILENAME = "client-ca.pem"

  # What `compress: true` offers. kamal-proxy has no "on" state without an
  # explicit list - --compress *is* the list - so the shorthand has to pick.
  # Best ratio first, matching the proxy's own default ordering; the client's
  # Accept-Encoding q-values still outrank this preference.
  DEFAULT_COMPRESSION_ENCODINGS = %w[ zstd br gzip ].freeze

  SUPPORTED_COMPRESSION_ENCODINGS = %w[ gzip br zstd ].freeze

  # kamal-proxy maps `brotli` onto the `br` token that travels in Content-Encoding.
  COMPRESSION_ENCODING_ALIASES = { "brotli" => "br" }.freeze

  delegate :argumentize, :optionize, :seconds_duration, to: Kamal::Utils

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
    return primary_role_first_host if auto_load_balanced_primary_role?

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

  def tls_config
    proxy_config["tls"] || {}
  end

  def on_demand_url
    tls_config["on_demand_url"]
  end

  # A path on the machine running kamal, like error_pages_path - not on the
  # deploy host. Kamal uploads it into the app's TLS directory, which the proxy
  # container already mounts, and hands the proxy the path it sees there.
  def client_ca_path
    tls_config["client_ca_path"]
  end

  def client_ca?
    client_ca_path.present?
  end

  def host_client_ca
    tls_file_path(config.proxy_boot.tls_directory, CLIENT_CA_FILENAME) if client_ca?
  end

  def container_client_ca
    tls_file_path(config.proxy_boot.tls_container_directory, CLIENT_CA_FILENAME) if client_ca?
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
      "path-timeout": path_timeout_args("path_timeouts"),
      "request-timeout": seconds_duration(proxy_config["request_timeout"]),
      "path-request-timeout": path_timeout_args("path_request_timeouts"),
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
      "error-pages": error_pages,
      # A deploy flag despite reading like metrics configuration: where the
      # metrics are served and who may read them are proxy-wide and live under
      # proxy/run, but which of *this service's* paths are counted is per service.
      "exclude-metrics-path": proxy_config["exclude_metrics_paths"].presence
    }.merge(tls_domains_options).merge(tls_options).merge(cache_options).merge(compress_options)
      .merge(access_control_options).merge(traffic_options).merge(lifecycle_options)
      .merge(target_options).compact

    if load_balancing?
      opts.delete(:host)
      opts.delete(:tls)
      tls_domains_options.each_key { |key| opts.delete(key) }
      tls_options.each_key { |key| opts.delete(key) }
      access_control_options.each_key { |key| opts.delete(key) }
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

    # Auto-activation needs a role the load balancer can actually front. The
    # target list is built from roles where `running_proxy?` (see
    # Kamal::Cli::Proxy#loadbalancer), so a proxy-less primary role would boot a
    # load balancer with an empty --target. An explicit `loadbalancer:` setting
    # skips this check — the operator asked for it.
    def auto_load_balanced_primary_role?
      primary_role = config.primary_role

      primary_role.present? && primary_role.running_proxy? && Array(primary_role.hosts).size > 1
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

    # On-demand issuance, the mTLS client CA and the ACME cache only matter where
    # the handshake happens. Like host/tls/tls-domains they are stripped from the
    # per-app deploy when load balancing and re-added by
    # Kamal::Configuration::Loadbalancer#deploy_options - an ask endpoint or a
    # client CA on a proxy that never terminates TLS would do nothing at all.
    def tls_options
      {
        "tls-on-demand-url": on_demand_url,
        "tls-client-ca-path": container_client_ca,
        "tls-acme-cache-path": tls_config["acme_cache_path"]
      }.compact
    end

    # The connection pool between the proxy and this app's containers, and how
    # hard the proxy tries to place a request on a healthy one.
    #
    # Every value is passed through exactly as written. kamal-proxy resolves its
    # own defaults from a zero (target_pool.go), and it has to do that server
    # side because restored state and older RPC clients never see the CLI — so
    # substituting a default here would be both redundant and wrong.
    def target_options
      target = proxy_config["target"] || {}

      {
        "target-max-conns": target["max_conns"],
        "target-max-idle-conns": target["max_idle_conns"],
        "target-idle-conn-timeout": seconds_duration(target["idle_conn_timeout"]),
        "target-dial-timeout": seconds_duration(target["dial_timeout"]),
        "target-disable-keep-alives": target["disable_keep_alives"] ? true : nil,
        "target-try-duration": seconds_duration(target["try_duration"]),
        "target-try-interval": seconds_duration(target["try_interval"])
      }.compact
    end

    # Session affinity and scale-to-zero: which target a client keeps, and
    # whether the targets are running at all.
    #
    # Sleep needs the container runtime socket, which is a run-level setting -
    # Kamal::Configuration#ensure_sleep_has_a_docker_socket refuses the pairing
    # rather than letting the first request after an idle period hang.
    def lifecycle_options
      affinity = proxy_config["session_affinity"] || {}
      sleep_config = proxy_config["sleep"] || {}
      affinity_enabled = affinity["enabled"] ? true : nil

      {
        "session-affinity": affinity_enabled,
        "session-affinity-cookie": (affinity["cookie"] if affinity_enabled),
        "sleep-after": seconds_duration(sleep_config["after"]),
        "wake-timeout": seconds_duration(sleep_config["wake_timeout"]),
        "sleep-container": sleep_config["containers"].presence
      }.compact
    end

    # Header rewriting, redirects, rewrites and error interception.
    #
    # Unlike TLS and access control these stay on the per-host proxy when load
    # balancing — Kamal::Configuration::Loadbalancer#deploy_options drops them.
    # The load balancer forwards to the per-host proxies, so applying the group
    # at both layers would append an `add` header twice and run a rewrite over
    # its own output.
    def traffic_options
      {
        "set-request-header": header_rules("request", "set"),
        "add-request-header": header_rules("request", "add"),
        "remove-request-header": headers_config.dig("request", "remove").presence,
        "set-response-header": header_rules("response", "set"),
        "add-response-header": header_rules("response", "add"),
        "remove-response-header": headers_config.dig("response", "remove").presence,
        redirect: path_rules("redirects"),
        rewrite: path_rules("rewrites"),
        "canonical-host": proxy_config["canonical_host"],
        "scope-cookie-paths": proxy_config["scope_cookie_paths"] ? true : nil,
        "intercept-errors": proxy_config["intercept_errors"].presence
      }.compact
    end

    def headers_config
      proxy_config["headers"] || {}
    end

    # kamal-proxy cuts a rule at the first colon, so a value carrying colons of
    # its own arrives intact.
    def header_rules(direction, verb)
      (headers_config.dig(direction, verb) || {}).map { |name, value| "#{name}: #{value}" }.presence
    end

    # '<pattern>=<replacement>', with ';status=<code>' appended for a redirect
    # that asks for one. Cut at the first '=' on the proxy side.
    def path_rules(key)
      Array(proxy_config[key]).map do |rule|
        "#{rule["from"]}=#{rule["to"]}#{";status=#{rule["status"]}" if rule["status"]}"
      end.presence
    end

    # Rate limiting, the IP allow list, and the client-IP identification both of
    # them key on. Stripped when load balancing and re-added by
    # Kamal::Configuration::Loadbalancer#deploy_options: the per-host proxy's peer
    # is the load balancer, so an allow list here would refuse every request and
    # one limiter would count the whole fleet as a single client.
    def access_control_options
      client_ip = proxy_config["client_ip"] || {}
      rate_limit = proxy_config["rate_limit"] || {}

      {
        "allow-ip": proxy_config["allow_ips"].presence,
        "trusted-proxy": client_ip["trusted_proxies"].presence,
        "client-ip-header": client_ip["header"],
        "rate-limit": rate_limit["requests"],
        "rate-limit-burst": rate_limit["burst"],
        "rate-limit-exempt": rate_limit["exempt"].presence
      }.compact
    end

    # `compress: true` and the block form both land here. --compress is a list of
    # encodings rather than a switch, so "on" always means naming them: a bare
    # --compress would take the next flag on the command line as its value.
    def compress_options
      compress = proxy_config["compress"]
      settings = compress.is_a?(Hash) ? compress : {}
      return {} unless compress == true || settings["enabled"] || settings["encodings"].present?

      {
        compress: settings["encodings"].presence || DEFAULT_COMPRESSION_ENCODINGS,
        "compress-content-type": settings["content_types"].presence,
        "compress-min-length": settings["min_length"]
      }.compact
    end

    # The cache policy, which is per service - the store it writes into is
    # proxy-wide and lives in proxy/run/cache. Only --cache is derived from a
    # truthy key; every other default stays in kamal-proxy, so an unset key emits
    # nothing rather than restating a default the gem would then have to track.
    def cache_options
      cache = proxy_config["cache"] || {}

      {
        cache: cache["enabled"] ? true : nil,
        "cache-max-ttl": seconds_duration(cache["max_ttl"]),
        "cache-max-body": cache["max_body"],
        "cache-max-variants": cache["max_variants"],
        "cache-vary-header": cache["vary_headers"].presence,
        "cache-vary-cookie": cache["vary_cookies"].presence,
        "cache-allow-set-cookie": cache["allow_set_cookie"] ? true : nil
      }.compact
    end

    def tls_path(directory, filename)
      tls_file_path(directory, filename) if custom_ssl_certificate?
    end

    # The path construction on its own: a client CA bundle lives beside the
    # server certificate but has nothing to do with whether one was configured.
    def tls_file_path(directory, filename)
      File.join([ directory, role_name, filename ].compact)
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

    # Serves both --path-timeout and --path-request-timeout, which kamal-proxy
    # reads with one parser. A duration may be a Go string ("5m") or plain
    # seconds; 0 is a value, meaning no limit for that prefix.
    def path_timeout_args(key)
      if (timeouts = proxy_config[key]).present?
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
