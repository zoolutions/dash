class Dash::Configuration::Proxy::Run
  MINIMUM_VERSION = "v1.1.0.1"
  DEFAULT_HTTP_PORT = 80
  DEFAULT_HTTPS_PORT = 443
  DEFAULT_LOG_MAX_SIZE = "10m"

  # One env file for everything the proxy must know but nothing may print:
  # ACME DNS credentials and the cache store URL. Also referenced by
  # Dash::Commands::Proxy#remove_proxy_secrets_file, which cleans it up when
  # the config no longer needs it.
  SECRETS_FILENAME = "secrets.env"

  # Bump when the digest serialization changes, so every host converges with
  # exactly one reboot after upgrading kamal.
  DIGEST_SCHEMA_VERSION = "v1"

  attr_reader :config, :run_config
  delegate :argumentize, :optionize, :seconds_duration, to: Dash::Utils

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
  # The secret *names* ride along because --env-file names a path, not the
  # variables inside it: swapping one credential for another (or adding the
  # cache store) would otherwise leave the digest unmoved and the old proxy
  # running. The values deliberately stay out — the digest is published as a
  # docker label, and hashing secret material into a world-readable label buys
  # an offline guessing target for nothing. Rotating a credential's value or
  # the store URL still needs an explicit `dash proxy reboot`.
  def config_digest
    self.class.digest(image, run_command, *docker_options_args, *secret_names)
  end

  def acme
    @acme ||= Dash::Configuration::Proxy::Acme.new(acme_config: run_config["acme"], secrets: config.secrets)
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
    run_config.fetch("repository", "ghcr.io/zoolutions/dash-proxy")
  end

  def image
    "#{[ registry, repository ].compact.join("/")}:#{version}"
  end

  def container_name
    "dash-proxy"
  end

  # Zero-downtime reboots: a minimal long-lived holder container owns the
  # published ports, and proxy generations join its network namespace so two
  # can overlap on the same ports during a handoff.
  def port_holder?
    run_config.fetch("port_holder", false)
  end

  def holder_container_name
    "dash-proxy-net"
  end

  def network_args
    if port_holder?
      [ "--network", "container:#{holder_container_name}" ]
    else
      [ "--network", "dash" ]
    end
  end

  def holder_docker_args
    [ *publish_args, *logging_args ].compact
  end

  def options_args
    if args = run_config["options"]
      optionize args
    end
  end

  def run_command
    [ "dash-proxy", "run", *optionize(run_command_options), *acme.run_command_args ].join(" ")
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

  # Anything dash-proxy accepts that has no key of its own yet. Values are
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
      *(publish_args unless port_holder?),
      *logging_args,
      *("--expose=#{metrics_port}" if metrics_port.present?),
      *secrets_args,
      *docker_socket_args,
      *options_args
    ].compact
  end

  # The flag only tells dash-proxy where to look inside its own container, so
  # without this mount the socket is not there and a sleeping service never
  # wakes - which the operator sees as one hung request, not as a misconfiguration.
  def docker_socket_args
    if docker_socket.present?
      Dash::Configuration::Volume.new(host_path: docker_socket, container_path: docker_socket).docker_args
    end
  end

  # Where the proxy's secrets land on the host - the ACME DNS credentials and
  # the cache store URL, which may embed one. Under the proxy's own directory
  # rather than the app's env directory, because the container is host-scoped
  # and shared by every app on the host - and so `dash proxy remove` takes
  # the secrets with it.
  def secrets_path
    File.join host_directory, SECRETS_FILENAME
  end

  def secrets?
    acme.credentials? || cache_store.present?
  end

  def secrets_io
    Dash::EnvFile.new(acme.credentials_env.merge(cache_store_env)).to_io
  end

  def host_directory
    File.join config.run_directory, "proxy"
  end

  def apps_directory
    File.join host_directory, "apps-config"
  end

  def apps_container_directory
    "/home/dash-proxy/.apps-config"
  end

  def apps_volume
    Dash::Configuration::Volume.new \
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
  # it. Dash::Configuration warns about this: the header rewrites the
  # connecting address that allow_ips and rate_limit key on, so honouring it
  # from anywhere is a client-IP spoofing hole.
  def proxy_protocol_unrestricted?
    run_config["proxy_protocol"] && Array(run_config["proxy_protocol_allow_ips"]).empty?
  end

  private
    # The proxy's own listeners and process-level behaviour, as opposed to the
    # per-service deadlines in Dash::Configuration::Proxy#deploy_options. Zero
    # disables each of the timeouts, so it is a value rather than an absence.
    def server_options
      {
        "log-format": run_config["log_format"],
        "trace-context": run_config["trace_context"],
        "min-tls": run_config["min_tls"]&.to_s,
        http3: run_config["http3"] ? true : nil,
        # port_holder needs two generations bound to :80/:443 at once, so the
        # holder topology forces the flag regardless of the standalone key.
        "reuse-port": (run_config["reuse_port"] || port_holder?) ? true : nil,
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
    # twice, and dash-proxy would silently take the last one. Refuse instead.
    # Only Proxy::Run knows which flags the named keys produce, so the check
    # cannot live in the validator with the rest.
    def ensure_no_conflicting_flags
      conflicts = flags.keys.map(&:to_s) & named_run_command_options.keys.map(&:to_s)
      return true if conflicts.empty?

      raise Dash::ConfigurationError,
        "#{@context}/flags: #{conflicts.sort.join(", ")} is already set by a named key - remove one of them"
    end

    # Where cached responses are kept, which is a property of the proxy rather
    # than of any one service - the policy that fills the cache is per service,
    # in proxy/cache. The store itself is deliberately absent: a store URL may
    # embed credentials, so it travels as CACHE_STORE in the secrets env file
    # (dash-proxy reads it as the --cache-store default) rather than on a
    # command line that lands in process listings and the audit log.
    def cache_options
      cache = run_config["cache"] || {}

      {
        "cache-store-timeout": seconds_duration(cache["store_timeout"]),
        "cache-memory-size": cache["memory_size"]
      }.compact
    end

    def cache_store
      run_config.dig("cache", "store")
    end

    def cache_store_env
      cache_store.present? ? { "CACHE_STORE" => cache_store } : {}
    end

    def secret_names
      [ *acme.credential_names, ("CACHE_STORE" if cache_store.present?) ].compact
    end

    def secrets_args
      argumentize "--env-file", secrets_path if secrets?
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
