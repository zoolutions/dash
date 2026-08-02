class Kamal::Configuration::Validator::Proxy < Kamal::Configuration::Validator
  def validate!
    unless config.nil?
      super

      # Skip SSL host validation when a loadbalancer is present (SSL is
      # disabled when using a loadbalancer) or when a tls_domains source
      # provides the hostnames at runtime.
      # On-demand TLS joins loadbalancer and tls_domains as a source of hostnames
      # that only exist at handshake time - demanding a static host here would
      # reject the one shape kamal-proxy requires for it.
      if config["host"].blank? && config["hosts"].blank? && config["ssl"] && config["loadbalancer"].blank? &&
         config.dig("tls_domains", "source").blank? && config.dig("tls", "on_demand_url").blank?
        error "Must set a host to enable automatic SSL"
      end

      if (config.keys & [ "host", "hosts" ]).size > 1
        error "Specify one of 'host' or 'hosts', not both"
      end

      if config.key?("loadbalancer")
        validate_loadbalancer! config["loadbalancer"]
      end

      if config["ssl"].is_a?(Hash)
        if config["ssl"]["certificate_pem"].present? && config["ssl"]["private_key_pem"].blank?
          error "Missing private_key_pem setting (required when certificate_pem is present)"
        end

        if config["ssl"]["private_key_pem"].present? && config["ssl"]["certificate_pem"].blank?
          error "Missing certificate_pem setting (required when private_key_pem is present)"
        end
      end

      # Truthiness, not present? — an empty hash must still fail the
      # "Missing source" check rather than silently disable the feature.
      if config["tls_domains"]
        validate_tls_domains! config["tls_domains"]
      end

      if config["basic_auth"].is_a?(Hash)
        validate_basic_auth! config["basic_auth"]
      end

      if config["tls"].is_a?(Hash)
        validate_tls! config["tls"]
      end

      if config["cache"].is_a?(Hash)
        validate_cache! config["cache"]
      end

      if config["compress"].is_a?(Hash)
        validate_compress! config["compress"]
      end

      validate_access_control!
      validate_traffic_shaping!
      validate_lifecycle!
      validate_tuning!

      if run_config = config["run"]
        if run_config["bind_ips"].present?
          ensure_valid_bind_ips(run_config["bind_ips"])
        end

        if run_config["publish"] == false
          if run_config["bind_ips"].present? || run_config["http_port"].present? || run_config["https_port"].present?
            error "Cannot set http_port, https_port or bind_ips when publish is false"
          end
        end

        if run_config["acme"].is_a?(Hash)
          validate_acme! run_config["acme"]
        end

        if run_config["cache"].is_a?(Hash)
          validate_cache_store! run_config["cache"]
        end

        validate_run_server_options! run_config
      end
    end
  end

  private
    # `true` picks the primary role's first host, `false` opts out of the
    # auto-activation that kicks in for a multi-host primary role, and a string
    # names the host to run the load balancer on — which may be a dedicated host
    # outside `servers:`, so we only check its shape.
    def validate_loadbalancer!(loadbalancer)
      with_context("loadbalancer") do
        return if loadbalancer == true || loadbalancer == false

        unless loadbalancer.is_a?(String) && loadbalancer.present? && !loadbalancer.match?(/[\s,]/)
          error "should be true, false, or a single host"
        end
      end
    end

    def validate_tls_domains!(tls_domains)
      with_context("tls_domains") do
        source = tls_domains["source"]

        if source.blank?
          error "Missing source setting (required when tls_domains is set)"
        elsif !valid_tls_domains_source?(source)
          error "source must be a path starting with '/' or an http(s) URL"
        end

        if (interval = tls_domains["interval"]) && (!interval.is_a?(Integer) || interval < 1)
          error "interval must be a positive integer"
        end

        if (batch_size = tls_domains["batch_size"]) && (!batch_size.is_a?(Integer) || !batch_size.between?(1, 25))
          error "batch_size must be an integer between 1 and 25"
        end
      end
    end

    # kamal-proxy only logs a warning for a DNS provider it does not recognise
    # and then carries on with no provider at all, so the symptom is a
    # certificate that never issues rather than a failed boot. Catch it here,
    # before any host is contacted.
    def validate_acme!(acme)
      with_context("run") do
        with_context("acme") do
          if acme["email"].blank?
            error "Missing email setting (required when acme is set)"
          end

          provider = acme["dns_provider"]

          if provider.present? && !Kamal::Configuration::Proxy::Acme::SUPPORTED_DNS_PROVIDERS.include?(provider.to_s.downcase)
            error "unsupported dns_provider '#{provider}'. " \
              "Supported providers: #{Kamal::Configuration::Proxy::Acme::DNS_PROVIDERS.join(", ")}"
          end
        end
      end
    end

    # kamal-proxy rejects each of these combinations outright rather than
    # picking a winner (ServiceOptions.Validate), so there is no precedence to
    # document - only a deploy that would fail after the SSH round-trip. Fail here.
    def validate_tls!(tls)
      with_context("tls") do
        on_demand_url = tls["on_demand_url"]
        client_ca_path = tls["client_ca_path"]

        if (on_demand_url.present? || client_ca_path.present?) && !config["ssl"]
          error "#{on_demand_url.present? ? "on_demand_url" : "client_ca_path"} requires ssl"
        end

        if on_demand_url.present?
          if config["host"].present? || config["hosts"].present?
            error "cannot set on_demand_url together with host or hosts - " \
              "on-demand TLS issues certificates for whatever hostnames the ask endpoint approves"
          end

          if config["ssl"].is_a?(Hash)
            error "cannot set on_demand_url together with a custom ssl certificate"
          end

          if config.dig("tls_domains", "source").present?
            error "cannot set on_demand_url together with tls_domains - " \
              "both manage certificates for hostnames discovered at runtime, and only one can serve the handshake"
          end

          unless valid_tls_domains_source?(on_demand_url)
            error "on_demand_url must be a path starting with '/' or an http(s) URL"
          end
        end

        if client_ca_path.present? && !File.exist?(client_ca_path)
          error "client_ca_path '#{client_ca_path}' does not exist"
        end
      end
    end

    REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze

    # An RFC 9110 token, which is both a valid header field name and a valid
    # cookie name. For a header, a space or a colon would also break the
    # '<name>: <value>' encoding kamal-proxy cuts at the first colon.
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    POOL_KEYS = %w[ max_conns max_idle_conns idle_conn_timeout dial_timeout try_duration try_interval ].freeze

    # A zero is meaningful for most of these, so only negatives are refused.
    # kamal-proxy clamps them rather than failing when it reads saved state, and
    # rejects them from a client — this is the client.
    def validate_tuning!
      target = config["target"] || {}

      with_context("target") do
        POOL_KEYS.each do |key|
          error "#{key} cannot be negative" if target[key].to_f.negative?
        end

        # A retry interval paces attempts within a duration; without one there is
        # only ever a single attempt for it to pace.
        if target["try_interval"].present? && target["try_duration"].to_i.zero?
          error "try_interval has no effect without try_duration"
        end
      end

      if config["request_timeout"].to_f.negative?
        with_context("request_timeout") { error "cannot be negative" }
      end

      # Both maps reach kamal-proxy's one parsePathTimeouts, which refuses a
      # negative duration.
      %w[ path_timeouts path_request_timeouts ].each do |key|
        with_context(key) do
          (config[key] || {}).each do |prefix, duration|
            error "'#{prefix}' cannot be negative" if duration.is_a?(Numeric) && duration.negative?
          end
        end
      end
    end

    # Session affinity and scale-to-zero. The one rule NOT here is that sleep
    # needs proxy/run/docker_socket: a role can carry `sleep` while the root
    # carries the socket, and this validator runs against the role's own proxy
    # block before it is merged. Kamal::Configuration checks that pairing on the
    # merged config instead.
    def validate_lifecycle!
      affinity = config["session_affinity"] || {}
      sleep_config = config["sleep"] || {}

      with_context("session_affinity") do
        if affinity["cookie"].present?
          if !affinity["enabled"]
            error "cookie has no effect without enabled: true"
          elsif !affinity["cookie"].to_s.match?(TOKEN)
            # net/http drops a cookie with an invalid name when it writes the
            # response, which looks exactly like affinity not working.
            error "cookie '#{affinity["cookie"]}' is not a valid cookie name"
          end
        end
      end

      with_context("sleep") do
        if sleep_config["after"].present?
          error "after cannot be negative" if sleep_config["after"].to_i.negative?
          error "wake_timeout cannot be negative" if sleep_config["wake_timeout"].to_i.negative?

          if config.dig("tls", "on_demand_url").present?
            error "after cannot be combined with tls/on_demand_url - " \
              "a sleeping target cannot answer the ask endpoint, and waking one would let any hostname start a container"
          end
        else
          error "containers has no effect without after" if sleep_config["containers"].present?
          error "wake_timeout has no effect without after" if sleep_config["wake_timeout"].present?
        end
      end
    end

    def validate_traffic_shaping!
      validate_header_rules!
      validate_path_rules! "redirects", redirect: true
      validate_path_rules! "rewrites", redirect: false

      with_context("intercept_errors") do
        Array(config["intercept_errors"]).each do |status|
          unless status.is_a?(Integer) && status.between?(400, 599)
            error "#{status} must be a 4xx or 5xx status code"
          end
        end
      end
    end

    def validate_header_shape!(headers)
      validate_type! headers, Hash

      with_context("headers") do
        unknown_keys_error(headers.keys - %w[ request response ]) if (headers.keys - %w[ request response ]).any?

        headers.each do |direction, rules|
          with_context(direction) do
            validate_type! rules, Hash
            unknown_keys_error(rules.keys - %w[ set add remove ]) if (rules.keys - %w[ set add remove ]).any?

            %w[ set add ].each { |verb| with_context(verb) { validate_hash_of! rules[verb], String } if rules.key?(verb) }
            with_context("remove") { validate_array_of! rules["remove"], String } if rules.key?("remove")
          end
        end
      end

      true
    end

    def validate_header_rules!
      headers = config["headers"] || {}

      with_context("headers") do
        %w[ request response ].each do |direction|
          rules = headers[direction] || {}

          with_context(direction) do
            %w[ set add ].each do |verb|
              with_context(verb) { (rules[verb] || {}).each { |name, value| validate_header_rule! direction, name, value } }
            end

            with_context("remove") { Array(rules["remove"]).each { |name| validate_header_rule! direction, name, nil } }
          end
        end
      end
    end

    def validate_header_rule!(direction, name, value)
      unless name.to_s.match?(TOKEN)
        return error "'#{name}' is not a valid header name"
      end

      # Go carries the request host in Request.Host rather than the header map,
      # so kamal-proxy refuses the rule instead of silently doing nothing.
      if direction == "request" && name.to_s.downcase == "host"
        return error "cannot rewrite the Host header"
      end

      # Escaping would turn a newline into a literal backslash-n, so the operator
      # would get a value they did not write, with no error. And CR/LF in a
      # header is response splitting.
      if value.to_s.match?(/[\r\n]/)
        error "'#{name}' has a value containing a newline or carriage return"
      end
    end

    # The pattern is deliberately not compiled: Go's RE2 and Ruby's Onigmo differ
    # at the edges (Ruby rejects Go's `(?P<name>...)`), and refusing a pattern
    # kamal-proxy would have accepted is worse than finding out at deploy time.
    def validate_path_rules!(key, redirect:)
      Array(config[key]).each_with_index do |rule, index|
        with_context(key) do
          with_context(index) do
            rule = {} unless rule.is_a?(Hash)

            if rule["from"].blank? || rule["to"].blank?
              next error "needs both from and to"
            end

            unless rule["to"].to_s.start_with?("/") || (redirect && rule["to"].to_s.match?(%r{\Ahttps?://}))
              next error "to must be an absolute path starting with '/'#{" or a full http(s) URL" if redirect}"
            end

            if rule["status"].present?
              if !redirect
                error "status is only meaningful for a redirect"
              elsif !REDIRECT_STATUSES.include?(rule["status"])
                error "status must be one of #{REDIRECT_STATUSES.join(", ")}"
              end
            end
          end
        end
      end
    end

    # kamal-proxy's --rate-limit is a Float64, so half a request per second is a
    # legal rate. The docs example can only demonstrate one numeric type, and an
    # Integer there would reject 0.5 — so the shape is checked by hand instead.
    def validate_key_override!(key, value)
      # Header names are the operator's to choose, so the docs example's names
      # are illustrations rather than the permitted set — the example-driven
      # unknown-key check would reject every real config. validate_header_rules!
      # does the semantic checking.
      return validate_header_shape!(value) if key.to_s == "headers"

      # The whole point of proxy/run/flags is that the gem does not know the flag
      # names, so the example's key is an illustration and the unknown-key check
      # would reject every real use. Proxy::Run rejects one that collides with a
      # named key; nothing else about the name is the gem's business.
      if key.to_s == "flags"
        validate_type! value, Hash
        with_context("flags") { validate_hash_of! value, String }
        return true
      end

      return false unless key.to_s == "rate_limit"

      validate_type! value, Hash

      with_context("rate_limit") do
        unknown_keys_error(value.keys - %w[ requests burst exempt ]) if (value.keys - %w[ requests burst exempt ]).any?

        with_context("requests") { validate_type! value["requests"], Numeric } if value.key?("requests")
        with_context("burst") { validate_type! value["burst"], Integer } if value.key?("burst")
        with_context("exempt") { validate_array_of! value["exempt"], String } if value.key?("exempt")
      end

      true
    end

    # Rate limiting and the IP allow list are only as correct as the address they
    # key on, so kamal-proxy ties the three settings together with rules that
    # otherwise surface only once the deploy has reached a host.
    def validate_access_control!
      allow_ips = Array(config["allow_ips"])
      client_ip = config["client_ip"] || {}
      rate_limit = config["rate_limit"] || {}
      trusted_proxies = Array(client_ip["trusted_proxies"])
      rate_limited = rate_limit["requests"].present?

      with_context("allow_ips") { allow_ips.each { |entry| validate_ip_entry! entry } }
      with_context("rate_limit") { with_context("exempt") { Array(rate_limit["exempt"]).each { |entry| validate_ip_entry! entry } } }

      with_context("client_ip") do
        with_context("trusted_proxies") do
          trusted_proxies.each do |entry|
            validate_ip_entry! entry

            # Trusting everything means trusting every client to speak for
            # someone else, which is the bypass this setting exists to prevent.
            if default_route?(entry)
              error "'#{entry}' is a default route - " \
                "trusting every address means trusting every client to speak for someone else"
            end
          end
        end

        if trusted_proxies.any? && allow_ips.empty? && !rate_limited
          error "trusted_proxies has no effect without allow_ips or rate_limit"
        end

        if client_ip["header"].present? && trusted_proxies.empty? && (allow_ips.any? || rate_limited)
          error "header requires trusted_proxies, or the header would be ignored while appearing to be honored"
        end
      end

      with_context("rate_limit") do
        if rate_limited
          error "requests cannot be negative" if rate_limit["requests"].to_f.negative?
          error "burst cannot be negative" if rate_limit["burst"].to_i.negative?
        else
          error "burst has no effect without requests" if rate_limit["burst"].present?
          error "exempt has no effect without requests" if rate_limit["exempt"].present?
        end
      end

      # kamal-proxy serves the health check path without an address check and
      # without a rate limit so deploys keep working, which makes '/' a hole
      # straight through both features.
      if (allow_ips.any? || rate_limited) && config.dig("healthcheck", "path") == "/"
        with_context("healthcheck") do
          error "path cannot be '/' when allow_ips or rate_limit is set, " \
            "as that path is served without an address check or a rate limit"
        end
      end
    end

    # IPAddr is looser than the proxy's netip parsing in two ways that matter: it
    # drops an IPv6 zone rather than rejecting it, and it accepts IPv4-mapped
    # forms. Both would match nothing at runtime while looking configured.
    def validate_ip_entry!(entry)
      if entry.to_s.include?("%")
        return error "'#{entry}' carries an IPv6 zone; write the address without it"
      end

      address = IPAddr.new(entry.to_s)

      if address.ipv4_mapped?
        error "'#{entry}' is IPv4-mapped; write it as plain IPv4"
      end
    rescue IPAddr::Error
      error "'#{entry}' is not a valid address or CIDR range"
    end

    def default_route?(entry)
      IPAddr.new(entry.to_s).prefix.zero?
    rescue IPAddr::Error
      false
    end

    # Mirrors CompressionOptions.Validate, which rejects each of these after the
    # deploy has already reached the host.
    def validate_compress!(compress)
      with_context("compress") do
        encodings = Array(compress["encodings"])
        enabled = compress["enabled"] || encodings.any?

        unless enabled
          if (orphaned = compress.keys - [ "enabled" ]).any?
            error "#{orphaned.first} has no effect without compression - set enabled: true or name the encodings"
          end

          return
        end

        encodings.each do |encoding|
          canonical = Kamal::Configuration::Proxy::COMPRESSION_ENCODING_ALIASES.fetch(encoding.to_s, encoding.to_s)

          unless Kamal::Configuration::Proxy::SUPPORTED_COMPRESSION_ENCODINGS.include?(canonical)
            error "unsupported encoding '#{encoding}'. " \
              "Supported encodings: #{Kamal::Configuration::Proxy::SUPPORTED_COMPRESSION_ENCODINGS.join(", ")}"
          end
        end

        if compress["min_length"].to_i.negative?
          error "min_length cannot be negative"
        end

        Array(compress["content_types"]).each do |content_type|
          # A main-type wildcard would match everything the proxy cannot see
          # inside, so kamal-proxy allows a wildcard only in the subtype.
          unless content_type.to_s.match?(%r{\A[^/*\s]+/[^/\s]+\z})
            error "content_types entry '#{content_type}' must be a media type such as text/html or text/*"
          end
        end
      end
    end

    LOG_FORMATS = %w[ json text logfmt ].freeze
    TRACE_CONTEXT_MODES = %w[ off propagate generate ].freeze
    MIN_TLS_VERSIONS = %w[ 1.2 1.3 ].freeze
    REFUSED_TLS_VERSIONS = %w[ 1.0 1.1 ].freeze
    RUN_TIMEOUTS = %w[ read_header_timeout read_timeout write_timeout idle_timeout shutdown_timeout ].freeze

    # kamal-proxy validates these three in preRun, so a typo does not fail the
    # deploy - it stops the proxy container from booting at all.
    def validate_run_server_options!(run_config)
      with_context("run") do
        if (format = run_config["log_format"]).present? && !LOG_FORMATS.include?(format.to_s.downcase.strip)
          error "log_format '#{format}' is not a log format - use json or text"
        end

        if (mode = run_config["trace_context"]).present? && !TRACE_CONTEXT_MODES.include?(mode.to_s.downcase.strip)
          error "trace_context '#{mode}' is not a trace context mode - use off, propagate or generate"
        end

        validate_min_tls! run_config["min_tls"]

        RUN_TIMEOUTS.each do |key|
          error "#{key} cannot be negative" if run_config[key].to_f.negative?
        end

        %w[ metrics_allow_ips proxy_protocol_allow_ips ].each do |key|
          with_context(key) { Array(run_config[key]).each { |entry| validate_ip_entry! entry } }
        end
      end
    end

    # Accepts the spellings kamal-proxy's normalizeTLSVersion reduces - a `tls`
    # or `tlsv` prefix, and `_` for `.` - so a config written for upstream is not
    # rejected here and accepted there.
    def validate_min_tls!(value)
      return if value.blank?

      normalized = value.to_s.downcase.strip.sub(/\Atlsv?/, "").tr("_", ".")

      if REFUSED_TLS_VERSIONS.include?(normalized)
        # The flag narrows what the listener negotiates; it was never a way to
        # widen it, and Go refuses these regardless.
        error "min_tls #{normalized} cannot be enabled - the lowest accepted minimum is #{MIN_TLS_VERSIONS.first}"
      elsif !MIN_TLS_VERSIONS.include?(normalized)
        error "min_tls '#{value}' is not a TLS version - use #{MIN_TLS_VERSIONS.join(" or ")}"
      end
    end

    # kamal-proxy reads the cache policy only when --cache is set and ignores it
    # otherwise, so a tuned block with no `enabled` is a cache that silently
    # never caches - this issue's own predicted first support question.
    def validate_cache!(cache)
      return if cache["enabled"]

      with_context("cache") do
        if (orphaned = cache.keys - [ "enabled" ]).any?
          error "#{orphaned.first} has no effect without enabled: true - " \
            "kamal-proxy ignores the cache policy entirely when --cache is absent"
        end
      end
    end

    # An unsupported store is rejected in kamal-proxy's preRun, which means the
    # proxy container exits at boot rather than a deploy failing. Catch it before
    # the fleet loses its proxy.
    def validate_cache_store!(cache)
      store = cache["store"]
      return if store.blank?

      with_context("run") do
        with_context("cache") do
          unless store == "memory" || store.to_s.match?(%r{\Arediss?://\S+\z})
            error "store must be 'memory' or a redis:// or rediss:// URL"
          end
        end
      end
    end

    def validate_basic_auth!(basic_auth)
      with_context("basic_auth") do
        if basic_auth["username"].blank?
          error "Missing username setting (required when basic_auth is set)"
        elsif basic_auth["username"].to_s.include?(":")
          # kamal-proxy cuts <username>:<password> at the first colon, so a
          # colon in the username would silently truncate it.
          error "Invalid username: cannot contain a colon"
        end

        if basic_auth["password"].present? && basic_auth["password_secret"].present?
          error "Specify one of 'password' or 'password_secret', not both"
        end

        if basic_auth["password"].blank? && basic_auth["password_secret"].blank?
          error "Missing password or password_secret setting (required when basic_auth is set)"
        end
      end
    end

    def valid_tls_domains_source?(source)
      source.is_a?(String) && (source.start_with?("/") || source.match?(%r{\Ahttps?://\S+\z}i))
    end

    def ensure_valid_bind_ips(bind_ips)
      bind_ips.present? && bind_ips.each do |ip|
        next if ip =~ Resolv::IPv4::Regex || ip =~ Resolv::IPv6::Regex
        error "Invalid publish IP address: #{ip}"
      end
    end
end
