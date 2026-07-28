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

  private
    def config
      Kamal::Configuration.new(@deploy)
    end

    def proxy_docs_example
      YAML.load(Kamal::Configuration::Proxy.validation_doc)["proxy"]
    end
end
