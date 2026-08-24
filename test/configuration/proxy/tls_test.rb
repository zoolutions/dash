require "test_helper"

class ConfigurationProxyTlsTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no ssl hash leaves the deploy command unchanged" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }

    assert_nil proxy_options(@deploy[:proxy])[:"tls-on-demand-url"]
    assert_nil proxy_options(@deploy[:proxy])[:"tls-client-ca-path"]
  end

  test "on_demand_url becomes --tls-on-demand-url" do
    options = proxy_options "ssl" => { "on_demand_url" => "https://app.example.com/api/v1/tls/ask" }

    assert_equal "https://app.example.com/api/v1/tls/ask", options[:"tls-on-demand-url"]
  end

  test "on_demand_url reaches the generated deploy command" do
    config = configuration "ssl" => { "on_demand_url" => "/api/v1/tls/ask" }

    assert_includes config.proxy.deploy_command_args(target: "1.1.1.1"),
      "--tls-on-demand-url=\"/api/v1/tls/ask\""
  end

  # A secret name, mirroring ssl.certificate_pem - never a local path. The flag
  # has to carry the container path the proxy sees inside its own mount.
  test "client_ca_pem is translated to a container path" do
    proxy = configuration("ssl" => { "client_ca_pem" => "CLIENT_CA_PEM" }, "host" => "example.com").proxy

    assert_equal ".kamal/proxy/apps-config/app/tls/client-ca.pem", proxy.host_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", proxy.container_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", proxy.deploy_options[:"tls-client-ca-path"]
    assert proxy.client_ca?
  end

  test "client_ca_pem is role-scoped like the server certificate" do
    config = Dash::Configuration.new @deploy.merge(
      servers: { "web" => { "hosts" => [ "1.1.1.1" ] } },
      proxy: { "ssl" => { "client_ca_pem" => "CLIENT_CA_PEM" }, "host" => "example.com" }
    )

    assert_equal ".kamal/proxy/apps-config/app/tls/web/client-ca.pem", config.role(:web).proxy.host_client_ca
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/web/client-ca.pem", config.role(:web).proxy.container_client_ca
  end

  # Resolved at upload time, not config time - `dash app logs` and `rollback`
  # must work on machines that do not hold the secret.
  test "client_ca_pem content is read from secrets at upload time" do
    with_test_secrets("secrets" => "CLIENT_CA_PEM=ca-bundle-content") do
      proxy = configuration("ssl" => { "client_ca_pem" => "CLIENT_CA_PEM" }, "host" => "example.com").proxy

      assert_equal "ca-bundle-content", proxy.client_ca_pem_content
    end
  end

  # A blank secret raises like basic_auth.password_secret - silently deploying
  # without the CA would turn mTLS off.
  test "an empty client_ca_pem secret raises" do
    with_test_secrets("secrets" => "CLIENT_CA_PEM=") do
      proxy = configuration("ssl" => { "client_ca_pem" => "CLIENT_CA_PEM" }, "host" => "example.com").proxy

      error = assert_raises(Dash::ConfigurationError) { proxy.client_ca_pem_content }
      assert_equal "proxy/ssl: client_ca_pem secret 'CLIENT_CA_PEM' is empty", error.message
    end
  end

  test "client_ca? is false without an ssl hash" do
    assert_not configuration("ssl" => true, "host" => "example.com").proxy.client_ca?
  end

  # kamal-proxy hard-rejects each of these combinations rather than picking a
  # winner, so the gem fails at config time with the same rules.
  test "on_demand_url cannot be combined with hosts" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "host" => "example.com", "ssl" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/ssl: cannot set on_demand_url together with host or hosts - " \
      "on-demand TLS issues certificates for whatever hostnames the ask endpoint approves", error.message
  end

  test "on_demand_url cannot be combined with a custom certificate" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      error = assert_raises(Dash::ConfigurationError) do
        configuration "ssl" => { "certificate_pem" => "CERT_PEM", "private_key_pem" => "KEY_PEM", "on_demand_url" => "/ask" }
      end

      assert_equal "proxy/ssl: cannot set on_demand_url together with a custom ssl certificate", error.message
    end
  end

  test "on_demand_url cannot be combined with ssl_domains" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "ssl_domains" => { "source" => "/domains" }, "ssl" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/ssl: cannot set on_demand_url together with ssl_domains - " \
      "both manage certificates for hostnames discovered at runtime, and only one can serve the handshake", error.message
  end

  test "on_demand_url must be a path or an http(s) URL" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "ssl" => { "on_demand_url" => "app.example.com/ask" }
    end

    assert_equal "proxy/ssl: on_demand_url must be a path starting with '/' or an http(s) URL", error.message
  end

  # ssl with no host is the *required* shape for on-demand TLS, so the
  # host check has to stand aside for it the way it already does for ssl_domains.
  test "ssl without a host is allowed when on_demand_url is set" do
    assert configuration("ssl" => { "on_demand_url" => "/ask" })
  end

  # TLS terminates at the load balancer, so an ask endpoint or a client CA
  # enforced on a per-app proxy behind it would never see a handshake.
  test "the tls flags move to the load balancer when load balancing" do
    proxy_config = {
      "loadbalancer" => "lb.example.com", "hosts" => [ "app.example.com" ],
      "ssl" => { "client_ca_pem" => "CLIENT_CA_PEM" }
    }
    config = configuration(proxy_config)

    assert_not config.proxy.deploy_options.key?(:"tls-client-ca-path")

    loadbalancer = Dash::Configuration::Loadbalancer.new config: config, proxy_config: proxy_config, secrets: config.secrets
    assert_equal "/home/kamal-proxy/.apps-config/app/tls/client-ca.pem", loadbalancer.deploy_options[:"tls-client-ca-path"]
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def proxy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
