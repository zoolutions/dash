class Kamal::Configuration::Proxy::Run
  MINIMUM_VERSION = "v1.0.0.0"
  DEFAULT_HTTP_PORT = 80
  DEFAULT_HTTPS_PORT = 443
  DEFAULT_LOG_MAX_SIZE = "10m"

  # Bump when the digest serialization changes, so every host converges with
  # exactly one reboot after upgrading kamal.
  DIGEST_SCHEMA_VERSION = "v1"

  attr_reader :config, :run_config
  delegate :argumentize, :optionize, :seconds_duration, to: Kamal::Utils

  def initialize(config, run_config:, context: "proxy/run")
    @config = config
    @run_config = run_config
    @context = context
    ensure_no_conflicting_flags
  end

  def self.digest(*parts)
    Digest::SHA256.hexdigest([ DIGEST_SCHEMA_VERSION, *parts ].join("\n"))
  end

  # Digest of the materialized run invocation, used to detect drift between
  # the running proxy container and the current configuration.
  #
  # The ACME credential names ride along because --env-file names a path, not the
  # variables inside it: swapping one credential for another would otherwise leave
  # the digest unmoved and the old proxy running. Their values deliberately stay
  # out — the digest is published as a docker label, and hashing secret material
  # into a world-readable label buys an offline guessing target for nothing.
  # Rotating a credential's value still needs an explicit `kamal proxy reboot`.
  def config_digest
    self.class.digest(image, run_command, *docker_options_args, *acme.credential_names)
  end

  def acme
    @acme ||= Kamal::Configuration::Proxy::Acme.new(acme_config: run_config["acme"], secrets: config.secrets)
  end

  def debug?
    run_config.fetch("debug", nil)
  end

  def publish?
    run_config.fetch("publish", true)
  end

  def http_port
    run_config.fetch("http_port", DEFAULT_HTTP_PORT)
  end

  def https_port
    run_config.fetch("https_port", DEFAULT_HTTPS_PORT)
  end

  def bind_ips
    run_config.fetch("bind_ips", nil)
  end

  def publish_args
    if publish?
      (bind_ips || [ nil ]).map do |bind_ip|
        bind_ip = format_bind_ip(bind_ip)
        publish_http = [ bind_ip, http_port, DEFAULT_HTTP_PORT ].compact.join(":")
        publish_https = [ bind_ip, https_port, DEFAULT_HTTPS_PORT ].compact.join(":")

        argumentize "--publish", [ publish_http, publish_https ]
      end.join(" ")
    end
  end

  def log_max_size
    run_config.fetch("log_max_size", DEFAULT_LOG_MAX_SIZE)
  end

  def logging_args
    argumentize "--log-opt", "max-size=#{log_max_size}" if log_max_size.present?
  end

  def version
    run_config.fetch("version", MINIMUM_VERSION)
  end

  def registry
    run_config.fetch("registry", nil)
  end

  def repository
    run_config.fetch("repository", "ghcr.io/mhenrixon/kamal-proxy")
  end

  def image
    "#{[ registry, repository ].compact.join("/")}:#{version}"
  end

  def container_name
    "kamal-proxy"
  end

  def options_args
    if args = run_config["options"]
      optionize args
    end
  end

  def run_command
    [ "kamal-proxy", "run", *optionize(run_command_options), *acme.run_command_args ].join(" ")
  end

  def metrics_port
    run_config["metrics_port"]
  end

  def run_command_options
    named_run_command_options.merge(flags)
  end

  # Everything the gem has a key for, as opposed to whatever `flags` passes
  # through. Kept separate so the two can be checked against each other.
  def named_run_command_options
    # recheck-targets-on-restore: after a reboot, re-verify restored targets
    # with live health checks instead of trusting the saved state — a dead
    # target demotes to 503 and self-heals rather than serving 502s forever.
    # Available from MINIMUM_VERSION, so it is always safe to pass.
    { debug: debug? || nil, "metrics-port": metrics_port, "recheck-targets-on-restore": true, "docker-socket": docker_socket }
      .compact.merge(cache_options).merge(server_options)
  end

  # Anything kamal-proxy accepts that has no key of its own yet. Values are
  # optionized as written - `true` is a bare flag, anything else takes a value -
  # because the point of an escape hatch is that the gem holds no opinion about
  # the flag it is forwarding.
  #
  # Note the asymmetry with `options`, which is a `docker run` passthrough. The
  # names are deliberately different; most of why this gap went unnoticed is
  # that `options` reads like it should do this.
  def flags
    (run_config["flags"] || {}).transform_keys(&:to_sym)
  end

  # What proxy/sleep needs in order to stop and start containers. Reaching this
  # socket is root-equivalent on the host, so nothing turns it on implicitly -
  # an operator has to name it, and naming it is also what mounts it (below).
  def docker_socket
    run_config["docker_socket"]
  end

  def docker_options_args
    [
      *apps_volume_args,
      *publish_args,
      *logging_args,
      *("--expose=#{metrics_port}" if metrics_port.present?),
      *acme_secrets_args,
      *docker_socket_args,
      *options_args
    ].compact
  end

  # The flag only tells kamal-proxy where to look inside its own container, so
  # without this mount the socket is not there and a sleeping service never
  # wakes - which the operator sees as one hung request, not as a misconfiguration.
  def docker_socket_args
    if docker_socket.present?
      Kamal::Configuration::Volume.new(host_path: docker_socket, container_path: docker_socket).docker_args
    end
  end

  # Where the ACME DNS credentials land on the proxy host. Under the proxy's own
  # directory rather than the app's env directory, because the container is
  # host-scoped and shared by every app on the host - and so `kamal proxy remove`
  # takes the credentials with it.
  def secrets_path
    File.join host_directory, "acme.env"
  end

  def secrets_io
    acme.secrets_io
  end

  def host_directory
    File.join config.run_directory, "proxy"
  end

  def apps_directory
    File.join host_directory, "apps-config"
  end

  def apps_container_directory
    "/home/kamal-proxy/.apps-config"
  end

  def apps_volume
    Kamal::Configuration::Volume.new \
      host_path: apps_directory,
      container_path: apps_container_directory
  end

  def apps_volume_args
    [ apps_volume.docker_args ]
  end

  def app_directory
    File.join apps_directory, config.service_and_destination
  end

  def app_container_directory
    File.join apps_container_directory, config.service_and_destination
  end

  def ==(other)
    other.is_a?(self.class) && run_config == other.run_config
  end
  alias_method :eql?, :==

  def hash
    run_config.hash
  end

  # Whether an operator turned on PROXY protocol without saying who may speak
  # it. Kamal::Configuration warns about this: the header rewrites the
  # connecting address that allow_ips and rate_limit key on, so honouring it
  # from anywhere is a client-IP spoofing hole.
  def proxy_protocol_unrestricted?
    run_config["proxy_protocol"] && Array(run_config["proxy_protocol_allow_ips"]).empty?
  end

  private
    # The proxy's own listeners and process-level behaviour, as opposed to the
    # per-service deadlines in Kamal::Configuration::Proxy#deploy_options. Zero
    # disables each of the timeouts, so it is a value rather than an absence.
    def server_options
      {
        "log-format": run_config["log_format"],
        "trace-context": run_config["trace_context"],
        "min-tls": run_config["min_tls"]&.to_s,
        http3: run_config["http3"] ? true : nil,
        "reuse-port": run_config["reuse_port"] ? true : nil,
        "ignore-restore-errors": run_config["ignore_restore_errors"] ? true : nil,
        "proxy-protocol": run_config["proxy_protocol"] ? true : nil,
        "proxy-protocol-allow-ip": run_config["proxy_protocol_allow_ips"].presence,
        "metrics-allow-ip": run_config["metrics_allow_ips"].presence,
        "read-header-timeout": seconds_duration(run_config["read_header_timeout"]),
        "read-timeout": seconds_duration(run_config["read_timeout"]),
        "write-timeout": seconds_duration(run_config["write_timeout"]),
        "idle-timeout": seconds_duration(run_config["idle_timeout"]),
        "shutdown-timeout": seconds_duration(run_config["shutdown_timeout"])
      }.compact
    end

    # A passthrough flag that a named key already emits would be optionized
    # twice, and kamal-proxy would silently take the last one. Refuse instead.
    # Only Proxy::Run knows which flags the named keys produce, so the check
    # cannot live in the validator with the rest.
    def ensure_no_conflicting_flags
      conflicts = flags.keys.map(&:to_s) & named_run_command_options.keys.map(&:to_s)
      return true if conflicts.empty?

      raise Kamal::ConfigurationError,
        "#{@context}/flags: #{conflicts.sort.join(", ")} is already set by a named key - remove one of them"
    end

    # Where cached responses are kept, which is a property of the proxy rather
    # than of any one service - the policy that fills the cache is per service,
    # in proxy/cache.
    #
    # lease_ttl and lease_wait take negative values to switch cross-node
    # coalescing off. That survives the space-separated rendering the rest of
    # this command uses: pflag reads the argument after `--flag` unconditionally,
    # without treating a leading dash as the next flag.
    def cache_options
      cache = run_config["cache"] || {}

      {
        "cache-store": cache["store"],
        "cache-store-timeout": seconds_duration(cache["store_timeout"]),
        "cache-memory-size": cache["memory_size"],
        "cache-lease-ttl": seconds_duration(cache["lease_ttl"]),
        "cache-lease-wait": seconds_duration(cache["lease_wait"])
      }.compact
    end

    def acme_secrets_args
      argumentize "--env-file", secrets_path if acme.credentials?
    end

    def format_bind_ip(ip)
      # Ensure IPv6 address inside square brackets - e.g. [::1]
      if ip =~ Resolv::IPv6::Regex && ip !~ /\A\[.*\]\z/
        "[#{ip}]"
      else
        ip
      end
    end
end
