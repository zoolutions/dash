require "test_helper"

# proxy/redirects_source: the dynamic redirect map (dash-proxy --redirects-source /
# --redirects-interval). Edge disposition — redirects answer at the loadbalancer,
# like ssl_domains and canonical_host.
class ConfigurationProxyRedirectsSourceTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "redirects_source flags in deploy_options" do
    options = deploy_options "redirects_source" => { "source" => "/api/v1/proxy/redirects", "interval" => 300 }

    assert_equal "/api/v1/proxy/redirects", options[:"redirects-source"]
    assert_equal "300s", options[:"redirects-interval"]
  end

  test "redirects_source flags absent when not configured" do
    options = deploy_options({})

    assert_not options.key?(:"redirects-source")
    assert_not options.key?(:"redirects-interval")
  end

  test "redirects_source with source only leaves the interval to the proxy default" do
    options = deploy_options "redirects_source" => { "source" => "https://app.example.com/redirects" }

    assert_equal "https://app.example.com/redirects", options[:"redirects-source"]
    assert_not options.key?(:"redirects-interval")
  end

  # Static redirects compose with the map: the map is consulted first, static
  # rules run when it misses. Both may be configured at once.
  test "redirects_source composes with static redirects" do
    options = deploy_options \
      "redirects_source" => { "source" => "/redirects" },
      "redirects" => [ { "from" => "/old", "to" => "/new" } ]

    assert_equal "/redirects", options[:"redirects-source"]
    assert_equal [ "/old=/new" ], options[:redirect]
  end

  test "deploy_options strips redirects_source when load balancing" do
    options = deploy_options \
      "loadbalancer" => "lb.example.com",
      "redirects_source" => { "source" => "/redirects", "interval" => 300 }

    assert_not options.key?(:"redirects-source")
    assert_not options.key?(:"redirects-interval")
  end

  test "redirects_source without source" do
    assert_raises(Dash::ConfigurationError) { configuration "redirects_source" => { "interval" => 300 } }
    assert_raises(Dash::ConfigurationError) { configuration "redirects_source" => {} }
  end

  test "redirects_source source must be a path or http url" do
    [ "example.com/redirects", "ftp://example.com/redirects", "redirects" ].each do |source|
      assert_raises(Dash::ConfigurationError, "expected #{source.inspect} to be rejected") do
        configuration "redirects_source" => { "source" => source }
      end
    end
  end

  # dash-proxy rejects an interval below MinRedirectsInterval (10s) after the
  # SSH round trip; catch it at config time instead.
  test "redirects_source interval must be an integer of at least 10 seconds" do
    [ 0, -300, "300", 1.5, 9 ].each do |interval|
      assert_raises(Dash::ConfigurationError, "expected interval #{interval.inspect} to be rejected") do
        configuration "redirects_source" => { "source" => "/redirects", "interval" => interval }
      end
    end
  end

  test "redirects_source interval accepts the proxy minimum" do
    assert_equal "10s", deploy_options("redirects_source" => { "source" => "/redirects", "interval" => 10 })[:"redirects-interval"]
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
