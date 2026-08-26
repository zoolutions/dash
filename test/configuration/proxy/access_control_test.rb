require "test_helper"

class ConfigurationProxyAccessControlTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no access control keys leave the deploy command unchanged" do
    options = deploy_options({})

    %i[ allow-ip trusted-proxy client-ip-header rate-limit rate-limit-burst rate-limit-exempt ].each do |flag|
      assert_not options.key?(flag), "expected no --#{flag}"
    end
  end

  test "allow_ips becomes --allow-ip" do
    assert_equal [ "10.0.0.0/8", "192.168.0.0/16" ],
      deploy_options("allow_ips" => [ "10.0.0.0/8", "192.168.0.0/16" ])[:"allow-ip"]
  end

  test "allow_ips reach the proxy as repeated flags" do
    args = configuration("allow_ips" => [ "10.0.0.0/8", "192.168.0.0/16" ])
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--allow-ip=\"10.0.0.0/8\""
    assert_includes args, "--allow-ip=\"192.168.0.0/16\""
  end

  test "rate_limit becomes the three rate flags" do
    options = deploy_options "rate_limit" => { "requests" => 100, "burst" => 20, "exempt" => [ "10.0.0.0/8" ] }

    assert_equal 100, options[:"rate-limit"]
    assert_equal 20, options[:"rate-limit-burst"]
    assert_equal [ "10.0.0.0/8" ], options[:"rate-limit-exempt"]
  end

  # The proxy's flag is a Float64 — one request every two seconds is legitimate.
  test "a fractional rate is passed through as written" do
    assert_equal 0.5, deploy_options("rate_limit" => { "requests" => 0.5 })[:"rate-limit"]
  end

  test "client_ip becomes --client-ip-header and --trusted-proxy" do
    options = deploy_options \
      "allow_ips" => [ "10.0.0.0/8" ],
      "client_ip" => { "header" => "CF-Connecting-IP", "trusted_proxies" => [ "173.245.48.0/20" ] }

    assert_equal "CF-Connecting-IP", options[:"client-ip-header"]
    assert_equal [ "173.245.48.0/20" ], options[:"trusted-proxy"]
  end

  # The per-app proxy's peer is the load balancer, never the client: allow_ips
  # there would 403 everything and the limiter would bucket the fleet as one.
  test "access control moves to the load balancer when load balancing" do
    proxy_config = {
      "loadbalancer" => "lb.example.com", "ssl" => true, "hosts" => [ "app.example.com" ],
      "allow_ips" => [ "10.0.0.0/8" ],
      "rate_limit" => { "requests" => 100 },
      "client_ip" => { "header" => "CF-Connecting-IP", "trusted_proxies" => [ "173.245.48.0/20" ] }
    }
    config = configuration(proxy_config)

    options = config.proxy.deploy_options
    %i[ allow-ip trusted-proxy client-ip-header rate-limit ].each do |flag|
      assert_not options.key?(flag), "expected --#{flag} to be stripped from the per-app deploy"
    end

    loadbalancer = Dash::Configuration::Loadbalancer.new config: config, proxy_config: proxy_config, secrets: config.secrets
    assert_equal [ "10.0.0.0/8" ], loadbalancer.deploy_options[:"allow-ip"]
    assert_equal 100, loadbalancer.deploy_options[:"rate-limit"]
    assert_equal "CF-Connecting-IP", loadbalancer.deploy_options[:"client-ip-header"]
    assert_equal [ "173.245.48.0/20" ], loadbalancer.deploy_options[:"trusted-proxy"]
  end

  # Address validation — Ruby's IPAddr is looser than the proxy's netip parsing

  test "a malformed CIDR fails locally" do
    error = assert_raises(Dash::ConfigurationError) { configuration "allow_ips" => [ "10.0.0.0/33" ] }

    assert_equal "proxy/allow_ips: '10.0.0.0/33' is not a valid address or CIDR range", error.message
  end

  test "an IPv6 zone is rejected because it would match nothing" do
    error = assert_raises(Dash::ConfigurationError) { configuration "allow_ips" => [ "fe80::1%eth0" ] }

    assert_equal "proxy/allow_ips: 'fe80::1%eth0' carries an IPv6 zone; write the address without it", error.message
  end

  test "an IPv4-mapped range is rejected because it would not match plain IPv4" do
    error = assert_raises(Dash::ConfigurationError) { configuration "allow_ips" => [ "::ffff:10.0.0.0/104" ] }

    assert_equal "proxy/allow_ips: '::ffff:10.0.0.0/104' is IPv4-mapped; write it as plain IPv4", error.message
  end

  test "rate_limit exempt entries are validated too" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "rate_limit" => { "requests" => 100, "exempt" => [ "nope" ] }
    end

    assert_equal "proxy/rate_limit/exempt: 'nope' is not a valid address or CIDR range", error.message
  end

  test "a default route in trusted_proxies is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "allow_ips" => [ "10.0.0.0/8" ], "client_ip" => { "trusted_proxies" => [ "0.0.0.0/0" ] }
    end

    assert_equal "proxy/client_ip/trusted_proxies: '0.0.0.0/0' is a default route - " \
      "trusting every address means trusting every client to speak for someone else", error.message
  end

  # Dependency rules dash-proxy enforces after the deploy reaches a host

  test "trusted_proxies without allow_ips or rate_limit is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "client_ip" => { "trusted_proxies" => [ "10.0.0.0/8" ] }
    end

    assert_equal "proxy/client_ip: trusted_proxies has no effect without allow_ips, deny_ips or rate_limit", error.message
  end

  test "a client_ip header without trusted_proxies is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "allow_ips" => [ "10.0.0.0/8" ], "client_ip" => { "header" => "CF-Connecting-IP" }
    end

    assert_equal "proxy/client_ip: header requires trusted_proxies, " \
      "or the header would be ignored while appearing to be honored", error.message
  end

  # Unconditionally, not only when allow_ips/rate_limit key on it: dash-proxy
  # rewrites the client address (and X-Forwarded-For) from the header for
  # logging and everything downstream, so honoring it from untrusted peers is
  # a client-spoofable identity - exactly what the shipped docs say it is not.
  test "a client_ip header without trusted_proxies is rejected even without allow_ips or rate_limit" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "client_ip" => { "header" => "CF-Connecting-IP" }
    end

    assert_equal "proxy/client_ip: header requires trusted_proxies, " \
      "or the header would be ignored while appearing to be honored", error.message
  end

  test "burst without requests is rejected" do
    error = assert_raises(Dash::ConfigurationError) { configuration "rate_limit" => { "burst" => 20 } }

    assert_equal "proxy/rate_limit: burst has no effect without requests", error.message
  end

  test "exempt without requests is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "rate_limit" => { "exempt" => [ "10.0.0.0/8" ] }
    end

    assert_equal "proxy/rate_limit: exempt has no effect without requests", error.message
  end

  test "a negative rate or burst is rejected" do
    assert_equal "proxy/rate_limit: requests cannot be negative",
      assert_raises(Dash::ConfigurationError) { configuration "rate_limit" => { "requests" => -1 } }.message

    assert_equal "proxy/rate_limit: burst cannot be negative",
      assert_raises(Dash::ConfigurationError) { configuration "rate_limit" => { "requests" => 100, "burst" => -1 } }.message
  end

  # dash-proxy serves the health check path without an address check or a rate
  # limit, so leaving it at / would quietly unrestrict the whole service.
  test "a root healthcheck path is rejected alongside access control" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "allow_ips" => [ "10.0.0.0/8" ], "healthcheck" => { "path" => "/" }
    end

    assert_equal "proxy/healthcheck: path cannot be '/' when allow_ips, deny_ips or rate_limit is set, " \
      "as that path is served without an address check or a rate limit", error.message
  end

  test "an unset healthcheck path is fine — the proxy defaults to /up" do
    assert configuration("allow_ips" => [ "10.0.0.0/8" ])
  end

  # AC1: a warning, not an error — the config is legal, just probably not what
  # the operator meant.
  test "rate limiting behind a proxy without trusted_proxies warns" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(
        proxy: { "forward_headers" => true, "rate_limit" => { "requests" => 100 } }
      )
    end

    assert_match "rate_limit is set with forward_headers", out
    assert_match "trusted_proxies", out
  end

  test "no warning once trusted_proxies is declared" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(
        proxy: {
          "forward_headers" => true,
          "rate_limit" => { "requests" => 100 },
          "client_ip" => { "trusted_proxies" => [ "10.0.0.0/8" ] }
        }
      )
    end

    assert_no_match(/rate_limit is set with forward_headers/, out)
  end

  test "no warning without forward_headers" do
    out = stderred { configuration("rate_limit" => { "requests" => 100 }) }

    assert_no_match(/rate_limit is set with forward_headers/, out)
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
