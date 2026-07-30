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
