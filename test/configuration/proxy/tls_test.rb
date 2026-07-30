require "test_helper"

class ConfigurationProxyTlsTest < ActiveSupport::TestCase
  CLIENT_CA = "test/fixtures/files/client-ca.pem"

  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no tls block leaves the deploy command unchanged" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }

    assert_equal proxy_options({ "ssl" => true, "host" => "example.com" }), proxy_options(@deploy[:proxy])
    assert_nil proxy_options(@deploy[:proxy])[:"tls-on-demand-url"]
    assert_nil proxy_options(@deploy[:proxy])[:"tls-client-ca-path"]
    assert_nil proxy_options(@deploy[:proxy])[:"tls-acme-cache-path"]
  end

  test "on_demand_url becomes --tls-on-demand-url" do
    options = proxy_options "ssl" => true, "tls" => { "on_demand_url" => "https://app.example.com/api/v1/tls/ask" }

    assert_equal "https://app.example.com/api/v1/tls/ask", options[:"tls-on-demand-url"]
  end

  test "on_demand_url reaches the generated deploy command" do
    config = configuration "ssl" => true, "tls" => { "on_demand_url" => "/api/v1/tls/ask" }

    assert_includes config.proxy.deploy_command_args(target: "1.1.1.1"),
      "--tls-on-demand-url=\"/api/v1/tls/ask\""
  end

  test "acme_cache_path passes through verbatim as a container path" do
    options = proxy_options "ssl" => true, "host" => "example.com",
      "tls" => { "acme_cache_path" => "/home/kamal-proxy/.config/kamal-proxy/acme" }

    assert_equal "/home/kamal-proxy/.config/kamal-proxy/acme", options[:"tls-acme-cache-path"]
  end

  # A host path handed straight to the proxy resolves inside the container and
  # silently fails, so the flag has to carry the container path - same treatment
  # ssl.certificate_pem already gets.
  test "client_ca_path is translated to a container path" do
    proxy = configuration("ssl" => true, "host" => "example.com", "tls" => { "client_ca_path" => CLIENT_CA }).proxy

    assert_equal ".kamal/proxy/apps-config/app/tls/client-ca.pem", proxy.host_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", proxy.container_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", proxy.deploy_options[:"tls-client-ca-path"]
    assert proxy.client_ca?
  end

  test "client_ca_path is role-scoped like the server certificate" do
    config = Kamal::Configuration.new @deploy.merge(
      servers: { "web" => { "hosts" => [ "1.1.1.1" ] } },
      proxy: { "ssl" => true, "host" => "example.com", "tls" => { "client_ca_path" => CLIENT_CA } }
    )

    assert_equal ".kamal/proxy/apps-config/app/tls/web/client-ca.pem", config.role(:web).proxy.host_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/web/client-ca.pem", config.role(:web).proxy.container_client_ca
  end

  test "client_ca? is false without a tls block" do
    assert_not configuration("ssl" => true, "host" => "example.com").proxy.client_ca?
  end

  # kamal-proxy hard-rejects each of these combinations rather than picking a
  # winner, so the gem fails at config time with the same rules.
  test "on_demand_url cannot be combined with hosts" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "ssl" => true, "host" => "example.com", "tls" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/tls: cannot set on_demand_url together with host or hosts - " \
      "on-demand TLS issues certificates for whatever hostnames the ask endpoint approves", error.message
  end

  test "on_demand_url cannot be combined with a custom certificate" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      error = assert_raises(Kamal::ConfigurationError) do
        configuration "ssl" => { "certificate_pem" => "CERT_PEM", "private_key_pem" => "KEY_PEM" },
          "tls" => { "on_demand_url" => "/ask" }
      end

      assert_equal "proxy/tls: cannot set on_demand_url together with a custom ssl certificate", error.message
    end
  end

  test "on_demand_url cannot be combined with tls_domains" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "ssl" => true, "tls_domains" => { "source" => "/domains" },
        "tls" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/tls: cannot set on_demand_url together with tls_domains - " \
      "both manage certificates for hostnames discovered at runtime, and only one can serve the handshake", error.message
  end

  test "on_demand_url requires ssl" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "tls" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/tls: on_demand_url requires ssl", error.message
  end

  test "client_ca_path requires ssl" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "host" => "example.com", "tls" => { "client_ca_path" => CLIENT_CA }
    end

    assert_equal "proxy/tls: client_ca_path requires ssl", error.message
  end

  test "on_demand_url must be a path or an http(s) URL" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "ssl" => true, "tls" => { "on_demand_url" => "app.example.com/ask" }
    end

    assert_equal "proxy/tls: on_demand_url must be a path starting with '/' or an http(s) URL", error.message
  end

  test "client_ca_path must name a readable file" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "ssl" => true, "host" => "example.com", "tls" => { "client_ca_path" => "test/fixtures/files/nope.pem" }
    end

    assert_equal "proxy/tls: client_ca_path 'test/fixtures/files/nope.pem' does not exist", error.message
  end

  # ssl: true with no host is the *required* shape for on-demand TLS, so the
  # host check has to stand aside for it the way it already does for tls_domains.
  test "ssl without a host is allowed when on_demand_url is set" do
    assert configuration("ssl" => true, "tls" => { "on_demand_url" => "/ask" })
  end

  # TLS terminates at the load balancer, so an ask endpoint or a client CA
  # enforced on a per-app proxy behind it would never see a handshake.
  test "the tls flags move to the load balancer when load balancing" do
    proxy_config = {
      "loadbalancer" => "lb.example.com", "ssl" => true, "hosts" => [ "app.example.com" ],
      "tls" => { "client_ca_path" => CLIENT_CA, "acme_cache_path" => "/cache" }
    }
    config = configuration(proxy_config)

    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-client-ca-path")
    assert_not options.key?(:"tls-acme-cache-path")

    loadbalancer = Kamal::Configuration::Loadbalancer.new config: config, proxy_config: proxy_config, secrets: config.secrets
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", loadbalancer.deploy_options[:"tls-client-ca-path"]
    assert_equal "/cache", loadbalancer.deploy_options[:"tls-acme-cache-path"]
  end

  private
    def configuration(proxy_config)
      Kamal::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def proxy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
