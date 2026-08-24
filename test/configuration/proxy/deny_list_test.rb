require "test_helper"

# proxy/deny_ips and proxy/deny_user_agents: kamal-proxy's --deny-ip and
# --deny-user-agent. Edge disposition, beside allow_ips and rate_limit — behind
# a loadbalancer the per-host proxies only ever see the LB as their peer.
class ConfigurationProxyDenyListTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no deny keys leave the deploy command unchanged" do
    options = deploy_options({})

    assert_not options.key?(:"deny-ip")
    assert_not options.key?(:"deny-user-agent")
  end

  test "deny_ips becomes --deny-ip" do
    assert_equal [ "203.0.113.0/24", "198.51.100.7" ],
      deploy_options("deny_ips" => [ "203.0.113.0/24", "198.51.100.7" ])[:"deny-ip"]
  end

  test "deny_user_agents becomes --deny-user-agent" do
    assert_equal [ "BadBot/.*", "Scraper.*" ],
      deploy_options("deny_user_agents" => [ "BadBot/.*", "Scraper.*" ])[:"deny-user-agent"]
  end

  test "deny rules reach the proxy as repeated flags" do
    args = configuration("deny_ips" => [ "203.0.113.0/24" ], "deny_user_agents" => [ "BadBot/.*" ])
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--deny-ip=\"203.0.113.0/24\""
    assert_includes args, "--deny-user-agent=\"BadBot/.*\""
  end

  test "deploy_options strips deny rules when load balancing" do
    options = deploy_options \
      "loadbalancer" => "lb.example.com",
      "deny_ips" => [ "203.0.113.0/24" ],
      "deny_user_agents" => [ "BadBot/.*" ]

    assert_not options.key?(:"deny-ip")
    assert_not options.key?(:"deny-user-agent")
  end

  # Same address validation as allow_ips - an entry IPAddr accepts but netip
  # rejects would match nothing at runtime while looking configured.
  test "an invalid deny_ips entry is rejected" do
    [ "not-an-ip", "203.0.113.0/24%eth0", "::ffff:203.0.113.7" ].each do |entry|
      assert_raises(Dash::ConfigurationError, "expected #{entry.inspect} to be rejected") do
        configuration "deny_ips" => [ entry ]
      end
    end
  end

  # The pattern is deliberately not compiled - Go's RE2 and Ruby's Onigmo
  # disagree at the edges, same as redirects/rewrites. Only the shape is checked.
  test "a blank deny_user_agents entry is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "deny_user_agents" => [ "" ]
    end

    assert_match "deny_user_agents", error.message
  end

  test "deny_user_agents must be an array of strings" do
    assert_raises(Dash::ConfigurationError) { configuration "deny_user_agents" => [ 42 ] }
  end

  # kamal-proxy serves the health check path without any of the address checks,
  # so a root health path would leave the whole service open to denied clients.
  test "a root healthcheck path is rejected alongside deny_ips" do
    assert_raises(Dash::ConfigurationError) do
      configuration "deny_ips" => [ "203.0.113.0/24" ], "healthcheck" => { "path" => "/" }
    end
  end

  # Warning parity with rate_limit: deny rules key on the client address, and
  # behind a fronting proxy without trusted_proxies they check the wrong one.
  test "deny_ips behind a proxy without trusted_proxies warns" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(
        proxy: { "forward_headers" => true, "deny_ips" => [ "203.0.113.0/24" ] }
      )
    end

    assert_match "deny_ips is set with forward_headers", out
    assert_match "trusted_proxies", out
  end

  test "no warning once trusted_proxies is declared" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(
        proxy: {
          "forward_headers" => true,
          "deny_ips" => [ "203.0.113.0/24" ],
          "client_ip" => { "trusted_proxies" => [ "10.0.0.0/8" ] }
        }
      )
    end

    assert_no_match(/deny_ips is set with forward_headers/, out)
  end

  # A user-agent match never keys on the client address, so it needs no warning.
  test "deny_user_agents alone does not warn" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(
        proxy: { "forward_headers" => true, "deny_user_agents" => [ "BadBot/.*" ] }
      )
    end

    assert_no_match(/forward_headers/, out)
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
