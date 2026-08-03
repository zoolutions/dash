require "test_helper"

class ConfigurationProxyTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "reboot_on_deploy defaults to true" do
    assert config.proxy.reboot_on_deploy?
  end

  test "reboot_on_deploy can be disabled" do
    @deploy[:proxy] = { "reboot_on_deploy" => false }
    assert_not config.proxy.reboot_on_deploy?
  end

  test "ssl with host" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with multiple hosts passed via host" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com,anotherexample.com" }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with multiple hosts passed via hosts" do
    @deploy[:proxy] = { "ssl" => true, "hosts" => [ "example.com", "anotherexample.com" ] }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with no host" do
    @deploy[:proxy] = { "ssl" => true }
    assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
  end

  test "ssl with both host and hosts" do
    @deploy[:proxy] = { "ssl" => true, host: "example.com", hosts: [ "anotherexample.com" ] }
    assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
  end

  test "ssl false" do
    @deploy[:proxy] = { "ssl" => false }
    assert_not config.proxy.ssl?
  end

  test "loadbalancer present" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }
    assert_equal "lb.example.com", config.proxy.loadbalancer
  end

  test "loadbalancer not present" do
    @deploy[:proxy] = {}
    assert_nil config.proxy.loadbalancer
  end

  test "effective_loadbalancer with explicit loadbalancer" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }
    assert_equal "lb.example.com", config.proxy.effective_loadbalancer
  end

  test "effective_loadbalancer with multiple web hosts but no explicit loadbalancer" do
    @deploy[:proxy] = { "hosts" => [] }
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ] }
    assert_equal "web1.example.com", config.proxy.effective_loadbalancer
  end

  test "effective_loadbalancer with single web host and no explicit loadbalancer" do
    @deploy[:proxy] = { "hosts" => [] }
    @deploy[:servers] = { "web" => [ "web1.example.com" ] }
    assert_nil config.proxy.effective_loadbalancer
  end

  test "effective_loadbalancer with loadbalancer true uses the primary role's first host" do
    @deploy[:proxy] = { "loadbalancer" => true }
    @deploy[:servers] = { "web" => [ "web1.example.com" ] }
    assert_equal "web1.example.com", config.proxy.effective_loadbalancer
    assert config.proxy.load_balancing?
  end

  test "effective_loadbalancer with loadbalancer false and multiple web hosts" do
    @deploy[:proxy] = { "loadbalancer" => false }
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ] }
    assert_equal false, config.proxy.effective_loadbalancer
    assert_not config.proxy.load_balancing?
  end

  test "effective_loadbalancer is nil when the multi-host primary role does not run the proxy" do
    @deploy[:servers] = { "workers" => { "proxy" => false, "hosts" => [ "1.1.1.1", "1.1.1.2" ] } }
    @deploy[:primary_role] = "workers"

    assert_nil config.proxy.effective_loadbalancer
    assert_not config.proxy.load_balancing?
  end

  test "explicit loadbalancer host still wins for a proxy-less primary role" do
    @deploy[:servers] = { "workers" => { "proxy" => false, "hosts" => [ "1.1.1.1", "1.1.1.2" ] } }
    @deploy[:primary_role] = "workers"
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }

    assert_equal "lb.example.com", config.proxy.effective_loadbalancer
  end

  test "explicit loadbalancer true still wins for a proxy-less primary role" do
    @deploy[:servers] = { "workers" => { "proxy" => false, "hosts" => [ "1.1.1.1", "1.1.1.2" ] } }
    @deploy[:primary_role] = "workers"
    @deploy[:proxy] = { "loadbalancer" => true }

    assert_equal "1.1.1.1", config.proxy.effective_loadbalancer
  end

  test "effective_loadbalancer auto-enables for a multi-host primary role that runs the proxy" do
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ], "workers" => { "proxy" => false, "hosts" => [ "1.1.1.1", "1.1.1.2" ] } }

    assert_equal "web1.example.com", config.proxy.effective_loadbalancer
  end

  test "loadbalancer true without any servers" do
    @deploy.delete(:servers)
    @deploy[:accessories] = { "db" => { "image" => "mysql", "host" => "1.1.1.5" } }
    @deploy[:proxy] = { "loadbalancer" => true }
    exception = assert_raises(Kamal::ConfigurationError) { config }
    assert_match "proxy/loadbalancer: can't be enabled without servers", exception.message
  end

  test "invalid loadbalancer values" do
    [ 123, "", "  ", "lb1.example.com,lb2.example.com", "lb.example.com extra" ].each do |value|
      @deploy[:proxy] = { "loadbalancer" => value }
      exception = assert_raises(Kamal::ConfigurationError, "expected #{value.inspect} to be rejected") { config.proxy }
      assert_match "proxy/loadbalancer: should be true, false, or a single host", exception.message
    end
  end

  test "loadbalancer as a list of hosts" do
    @deploy[:proxy] = { "loadbalancer" => [ "lb.example.com" ] }
    exception = assert_raises(Kamal::ConfigurationError) { config.proxy }
    assert_match "proxy/loadbalancer: should be a string", exception.message
  end

  test "load_balancing? returns true when loadbalancer is present" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }
    assert config.proxy.load_balancing?
  end

  test "load_balancing? returns true when multiple web hosts are present" do
    @deploy[:proxy] = { "hosts" => [] }
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ] }
    assert config.proxy.load_balancing?
  end

  test "load_balancing? returns false when no loadbalancer and single web host" do
    @deploy[:proxy] = { "hosts" => [] }
    @deploy[:servers] = { "web" => [ "web1.example.com" ] }
    assert_not config.proxy.load_balancing?
  end

  test "deploy_options disables SSL when loadbalancer is present" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }
    assert_equal false, config.proxy.deploy_options.key?(:tls)
  end

  test "deploy_options makes hosts optional when loadbalancer is present" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com", "hosts" => [ "app1.example.com" ] }
    assert_nil config.proxy.deploy_options[:host]
  end

  test "deploy_options uses hosts when no loadbalancer is present" do
    @deploy[:proxy] = { "hosts" => [ "app1.example.com" ] }
    assert_equal [ "app1.example.com" ], config.proxy.deploy_options[:host]
  end

  test "loadbalancer_on_proxy_host? returns true when loadbalancer is a web host" do
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ] }
    @deploy[:proxy] = { "loadbalancer" => "web1.example.com" }
    assert config.proxy.loadbalancer_on_proxy_host?
  end

  test "loadbalancer_on_proxy_host? returns false when loadbalancer is dedicated host" do
    @deploy[:servers] = { "web" => [ "web1.example.com", "web2.example.com" ] }
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com" }
    assert_not config.proxy.loadbalancer_on_proxy_host?
  end

  test "loadbalancer_on_proxy_host? returns false when no loadbalancer" do
    @deploy[:servers] = { "web" => [ "web1.example.com" ] }
    @deploy[:proxy] = {}
    assert_not config.proxy.loadbalancer_on_proxy_host?
  end

  test "invalid bind_ips" do
    [ "999.999.999.999", "localhost", "0.0.0.0/0" ].each do |ip|
      @deploy[:proxy] = { "run" => { "bind_ips" => [ ip ] } }
      exception = assert_raises(Kamal::ConfigurationError, "expected #{ip.inspect} to be rejected") { config.proxy }
      assert_match "Invalid publish IP address: #{ip}", exception.message
    end
  end

  test "valid bind_ips" do
    @deploy[:proxy] = { "run" => { "bind_ips" => [ "0.0.0.0", "127.0.0.1", "::1", "2001:db8::1" ] } }
    assert_equal [ "0.0.0.0", "127.0.0.1", "::1", "2001:db8::1" ], config.proxy.run.bind_ips
  end

  test "false not allowed" do
    @deploy[:proxy] = false
    assert_raises(Kamal::ConfigurationError, "proxy: should be a hash") do
      config.proxy
    end
  end

  # The docs YAML doubles as the validation schema and as `kamal docs proxy` output.
  # Guard the documented run defaults against drifting from the code's actual
  # defaults (a stale `version:` below MINIMUM_VERSION breaks `kamal proxy boot`
  # for anyone who copies the example).
  test "docs example run version matches the pinned minimum version" do
    assert_equal Kamal::Configuration::Proxy::Run::MINIMUM_VERSION, proxy_docs_example.dig("run", "version")
  end

  test "docs example run repository matches the code default" do
    default_repository = Kamal::Configuration::Proxy::Run.new(config, run_config: {}).repository
    assert_equal default_repository, proxy_docs_example.dig("run", "repository")
  end

  # The accessory docs stub `proxy: ...` is load-bearing: the validator treats the
  # example value "..." as "any hash — Proxy.new validates it against the real proxy
  # schema". Filling it with literal keys would fork the proxy schema into a second,
  # drift-prone copy that rejects valid accessory proxy configs.
  test "accessory docs keep the proxy example as a stub" do
    accessory_example = YAML.load(Kamal::Configuration::Accessory.validation_doc)
    assert_equal "...", accessory_example.dig("accessories", "mysql", "proxy")
  end

  test "ssl with certificate and private key from secrets" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM",
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }

      proxy = config.proxy
      assert_equal ".kamal/proxy/apps-config/app/tls/cert.pem", proxy.host_tls_cert
      assert_equal ".kamal/proxy/apps-config/app/tls/key.pem", proxy.host_tls_key
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/cert.pem", proxy.container_tls_cert
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/key.pem", proxy.container_tls_key
    end
  end

  test "deploy options with custom ssl certificates" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM",
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }

      proxy = config.proxy
      options = proxy.deploy_options
      assert_equal true, options[:tls]
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/cert.pem", options[:"tls-certificate-path"]
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/key.pem", options[:"tls-private-key-path"]
    end
  end

  test "deploy options with custom healthcheck port and host" do
    @deploy[:proxy] = { "healthcheck" => { "port" => 3001, "host" => "health.example.com" } }

    options = config.proxy.deploy_options
    assert_equal 3001, options[:"health-check-port"]
    assert_equal "health.example.com", options[:"health-check-host"]
  end

  test "deploy options without healthcheck port and host" do
    @deploy[:proxy] = { "healthcheck" => { "path" => "/health" } }

    options = config.proxy.deploy_options
    assert_not_includes options.keys, :"health-check-port"
    assert_not_includes options.keys, :"health-check-host"
  end

  test "healthcheck port must be an integer" do
    @deploy[:proxy] = { "healthcheck" => { "port" => "not-a-port" } }

    assert_raises(Kamal::ConfigurationError) { config.proxy }
  end

  test "healthcheck rejects unknown keys" do
    @deploy[:proxy] = { "healthcheck" => { "hosts" => [ "health.example.com" ] } }

    assert_raises(Kamal::ConfigurationError) { config.proxy }
  end

  test "ssl with certificate and no private key" do
    with_test_secrets("secrets" => "CERT_PEM=certificate") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM"
        },
        "host" => "example.com"
      }
      assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
    end
  end

  test "tls_domains flags in deploy_options" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "/api/v1/kamal/domains", "interval" => 300, "batch_size" => 5 } }
    options = config.proxy.deploy_options
    assert_equal "/api/v1/kamal/domains", options[:"tls-domains-source"]
    assert_equal "300s", options[:"tls-domains-interval"]
    assert_equal 5, options[:"tls-domains-batch-size"]
  end

  test "tls_domains flags absent when not configured" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-domains-source")
    assert_not options.key?(:"tls-domains-interval")
    assert_not options.key?(:"tls-domains-batch-size")
  end

  test "tls_domains with source only" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "https://app.example.com/domains" } }
    options = config.proxy.deploy_options
    assert_equal "https://app.example.com/domains", options[:"tls-domains-source"]
    assert_not options.key?(:"tls-domains-interval")
    assert_not options.key?(:"tls-domains-batch-size")
  end

  test "ssl with no host allowed when tls_domains source is set" do
    @deploy[:proxy] = { "ssl" => true, "tls_domains" => { "source" => "/domains" } }
    assert config.proxy.ssl?
  end

  test "deploy_options strips tls_domains flags when load balancing" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com", "ssl" => true, "hosts" => [ "app.example.com" ], "tls_domains" => { "source" => "/domains" } }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-domains-source")
    assert_not options.key?(:"tls-domains-interval")
    assert_not options.key?(:"tls-domains-batch-size")
  end

  # Session affinity: both layers used to pin with the same cookie name but
  # separate HMAC keys, so the inner proxy clobbered the edge pin every other
  # request — the edge is the only layer whose pin can stick.
  # Canonical host and redirects consult r.TLS only (kamal-proxy
  # redirectURLIfNeeded), so behind the LB they emitted http:// Locations to
  # HTTPS clients. Cache policy and read routing are edge decisions.
  test "deploy_options strips session affinity, canonical host, redirects, cache and read routing when load balancing" do
    @deploy[:proxy] = {
      "loadbalancer" => "lb.example.com",
      "session_affinity" => { "enabled" => true, "cookie" => "_kamal_affinity" },
      "canonical_host" => "www.example.com",
      "redirects" => [ { "from" => "/old", "to" => "/new", "status" => 302 } ],
      "cache" => { "enabled" => true, "max_ttl" => 300 },
      "read_targets" => [ "1.1.1.2" ],
      "read_target_websockets" => true,
      "writer_affinity_timeout" => 30
    }

    options = config.proxy.deploy_options

    %i[ session-affinity session-affinity-cookie canonical-host redirect
        cache cache-max-ttl read-target read-target-websockets writer-affinity-timeout ].each do |key|
      assert_not_includes options.keys, key
    end
  end

  # Sleep needs the docker socket and container names, which only exist on the
  # app hosts; compress must run once, next to the app, or the LB would
  # re-compress what the per-app proxy already encoded.
  test "deploy_options keeps sleep and compress per app when load balancing" do
    @deploy[:proxy] = {
      "loadbalancer" => "lb.example.com",
      "sleep" => { "after" => 300 },
      "compress" => true,
      "run" => { "docker_socket" => "/var/run/docker.sock" }
    }

    options = config.proxy.deploy_options

    assert_includes options.keys, :"sleep-after"
    assert_includes options.keys, :compress
  end

  # kamal-proxy gates TLSRedirect on TLSEnabled, and tls is already stripped
  # per-app — the whole TLS family terminates at the edge.
  test "deploy_options strips ssl staging and ssl redirect when load balancing" do
    @deploy[:proxy] = {
      "loadbalancer" => "lb.example.com", "hosts" => [ "app.example.com" ],
      "ssl" => true, "ssl_staging" => true, "ssl_redirect" => true
    }

    options = config.proxy.deploy_options

    assert_not_includes options.keys, :"tls-staging"
    assert_not_includes options.keys, :"tls-redirect"
  end

  # Each layer has a real connection pool between itself and its targets, so
  # pool tuning applies at both — deliberately, not by omission.
  test "deploy_options keeps target pool tuning at both layers when load balancing" do
    @deploy[:proxy] = { "loadbalancer" => "lb.example.com", "target" => { "max_conns" => 100 } }

    assert_includes config.proxy.deploy_options.keys, :"target-max-conns"
  end

  test "tls_domains without source" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "interval" => 300 } }
    assert_raises(Kamal::ConfigurationError) { config.proxy }
  end

  test "tls_domains empty hash" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => {} }
    assert_raises(Kamal::ConfigurationError) { config.proxy }
  end

  test "tls_domains source must be a path or http url" do
    [ "example.com/domains", "ftp://example.com/domains", "domains" ].each do |source|
      @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => source } }
      assert_raises(Kamal::ConfigurationError, "expected #{source.inspect} to be rejected") { config.proxy }
    end
  end

  test "tls_domains source accepts http and https urls" do
    [ "http://app.internal/domains", "https://app.example.com/api/v1/kamal/domains" ].each do |source|
      @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => source } }
      assert_equal source, config.proxy.deploy_options[:"tls-domains-source"]
    end
  end

  test "tls_domains interval must be a positive integer" do
    [ 0, -300, "300", 1.5 ].each do |interval|
      @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "/domains", "interval" => interval } }
      assert_raises(Kamal::ConfigurationError, "expected interval #{interval.inspect} to be rejected") { config.proxy }
    end
  end

  test "tls_domains batch_size must be between 1 and 25" do
    [ 0, 26, "5", 1.5 ].each do |batch_size|
      @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "/domains", "batch_size" => batch_size } }
      assert_raises(Kamal::ConfigurationError, "expected batch_size #{batch_size} to be rejected") { config.proxy }
    end

    [ 1, 25 ].each do |batch_size|
      @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "/domains", "batch_size" => batch_size } }
      assert_equal batch_size, config.proxy.deploy_options[:"tls-domains-batch-size"]
    end
  end

  test "tls_domains rejects unknown keys" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "tls_domains" => { "source" => "/domains", "sources" => "/other" } }
    assert_raises(Kamal::ConfigurationError) { config.proxy }
  end

  test "ssl with private key and no certificate" do
    with_test_secrets("secrets" => "KEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }
      assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
    end
  end

  test "ssl_staging, read_targets and writer affinity flags in deploy_options" do
    @deploy[:proxy] = {
      "ssl" => true, "host" => "example.com",
      "ssl_staging" => true,
      "read_targets" => [ "192.168.0.2:3000", "192.168.0.3:3000" ],
      "read_target_websockets" => true,
      "writer_affinity_timeout" => 10
    }
    options = config.proxy.deploy_options
    assert_equal true, options[:"tls-staging"]
    assert_equal [ "192.168.0.2:3000", "192.168.0.3:3000" ], options[:"read-target"]
    assert_equal true, options[:"read-target-websockets"]
    assert_equal "10s", options[:"writer-affinity-timeout"]
  end

  test "ssl_staging, read_targets and writer affinity flags absent when not configured" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-staging")
    assert_not options.key?(:"read-target")
    assert_not options.key?(:"read-target-websockets")
    assert_not options.key?(:"writer-affinity-timeout")
  end

  test "ssl_staging and read_target_websockets false emit no flags" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "ssl_staging" => false, "read_target_websockets" => false }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-staging")
    assert_not options.key?(:"read-target-websockets")
  end

  test "read_targets in deploy command args" do
    @deploy[:proxy] = { "host" => "example.com", "read_targets" => [ "192.168.0.2:3000" ] }
    args = config.proxy.deploy_command_args(target: "abc123:80")
    assert_includes args.join(" "), "--read-target=\"192.168.0.2:3000\""
  end

  test "invalid types for ssl_staging, read_targets and writer affinity keys" do
    {
      "ssl_staging" => "yes",
      "read_targets" => "192.168.0.2:3000",
      "read_target_websockets" => 1,
      "writer_affinity_timeout" => "10"
    }.each do |key, value|
      @deploy[:proxy] = { "host" => "example.com", key => value }
      assert_raises(Kamal::ConfigurationError, "expected #{key}=#{value.inspect} to be rejected") { config.proxy }
    end
  end

  test "deploy options with path timeouts" do
    @deploy[:proxy] = { "path_timeouts" => { "/api/reports" => "5m", "/uploads" => 120, "/stream" => 0 } }

    assert_equal [ "/api/reports=5m", "/uploads=120s", "/stream=0s" ], config.proxy.deploy_options[:"path-timeout"]
  end

  test "deploy options without path timeouts" do
    @deploy[:proxy] = { "host" => "example.com" }

    assert_not_includes config.proxy.deploy_options.keys, :"path-timeout"
  end

  test "path timeouts must be a hash" do
    @deploy[:proxy] = { "path_timeouts" => "/api=5m" }

    assert_raises(Kamal::ConfigurationError) { config }
  end

  test "path timeouts values must be stringish" do
    @deploy[:proxy] = { "path_timeouts" => { "/api" => [ "5m" ] } }

    assert_raises(Kamal::ConfigurationError) { config }
  end

  test "deploy options with basic auth" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password" => "s3cr3t" } }

    assert_equal "admin:s3cr3t", config.proxy.deploy_options[:"basic-auth"]
  end

  test "deploy options with basic auth password from secrets" do
    with_test_secrets("secrets" => "WEB_PASSWORD=s3cr3t") do
      @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password_secret" => "WEB_PASSWORD" } }

      assert_equal "admin:s3cr3t", config.proxy.deploy_options[:"basic-auth"]
    end
  end

  test "deploy options without basic auth" do
    @deploy[:proxy] = { "host" => "example.com" }

    assert_not_includes config.proxy.deploy_options.keys, :"basic-auth"
  end

  test "basic auth password may contain colons" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password" => "pa:ss:word" } }

    assert_equal "admin:pa:ss:word", config.proxy.deploy_options[:"basic-auth"]
  end

  test "basic auth requires a username" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "password" => "s3cr3t" } }

    error = assert_raises(Kamal::ConfigurationError) { config }
    assert_equal "proxy/basic_auth: Missing username setting (required when basic_auth is set)", error.message
  end

  test "basic auth requires a password or password_secret" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin" } }

    error = assert_raises(Kamal::ConfigurationError) { config }
    assert_equal "proxy/basic_auth: Missing password or password_secret setting (required when basic_auth is set)", error.message
  end

  test "basic auth rejects both password and password_secret" do
    @deploy[:proxy] = {
      "host" => "example.com",
      "basic_auth" => { "username" => "admin", "password" => "s3cr3t", "password_secret" => "WEB_PASSWORD" }
    }

    error = assert_raises(Kamal::ConfigurationError) { config }
    assert_equal "proxy/basic_auth: Specify one of 'password' or 'password_secret', not both", error.message
  end

  test "basic auth username must not contain a colon" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "ad:min", "password" => "s3cr3t" } }

    error = assert_raises(Kamal::ConfigurationError) { config }
    assert_equal "proxy/basic_auth: Invalid username: cannot contain a colon", error.message
  end

  test "basic auth rejects a non-hash" do
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => "admin:s3cr3t" }

    assert_raises(Kamal::ConfigurationError) { config }
  end

  # Never fail open: an empty secret must abort the deploy, not silently drop
  # the flag and leave the service unprotected.
  test "basic auth with an empty password secret raises" do
    with_test_secrets("secrets" => "WEB_PASSWORD=") do
      @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password_secret" => "WEB_PASSWORD" } }

      error = assert_raises(Kamal::ConfigurationError) { config.proxy.deploy_options }
      assert_match(/basic_auth/, error.message)
    end
  end

  test "basic auth with an unknown password secret raises" do
    with_test_secrets("secrets" => "OTHER_PASSWORD=s3cr3t") do
      @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password_secret" => "WEB_PASSWORD" } }

      assert_raises(Kamal::ConfigurationError) { config.proxy.deploy_options }
    end
  end

  # Basic auth is an edge concern. kamal-proxy deletes the Authorization header
  # once a service enforces basic auth, so emitting the flag on BOTH the load
  # balancer and the per-app proxy would have the load balancer authenticate,
  # strip the header, and the app proxy 401 every forwarded request.
  test "basic auth is left to the load balancer when load balancing" do
    @deploy[:servers] = { "web" => [ "1.1.1.1", "1.1.1.2" ] }
    @deploy[:proxy] = { "host" => "example.com", "basic_auth" => { "username" => "admin", "password" => "s3cr3t" } }

    assert config.proxy.load_balancing?
    assert_not_includes config.proxy.deploy_options.keys, :"basic-auth"
  end

  private
    def config
      Kamal::Configuration.new(@deploy)
    end

    def proxy_docs_example
      YAML.load(Kamal::Configuration::Proxy.validation_doc)["proxy"]
    end
end
