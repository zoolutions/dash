require "test_helper"

# The fork's load balancer auto-activates for any >1-host primary role, and
# every proxy deploy option must decide where it lives in that topology: at the
# edge, next to the app, or deliberately at both layers. The option groups that
# skipped the decision each shipped broken, doubled, or undecided in exactly
# the fork's headline topology (session affinity clobbered, sleep failing the
# LB deploy, compress running twice).
#
# So: every flag Dash::Configuration::Proxy#deploy_options can emit must have
# a disposition recorded in DEPLOY_OPTION_DISPOSITIONS. A new option without
# one fails the build here — the flag-coverage-canary pattern applied to
# layering, so the next feature cannot skip the decision.
#
# The key set is generated from the maximal fixtures rather than hand-written,
# for the same reason test/proxy_flag_coverage_test.rb generates its flag list:
# a hand-written list would go stale in exactly the way this test exists to
# prevent.
class ProxyLayeringTest < ActiveSupport::TestCase
  DISPOSITIONS = Dash::Configuration::Proxy::DEPLOY_OPTION_DISPOSITIONS

  # Same pair as the flag coverage canary: some options are mutually exclusive
  # (kamal-proxy forbids on-demand TLS alongside hosts, a custom certificate or
  # ssl_domains), so one fixture cannot emit every key. Coverage is the union.
  MAXIMAL_FIXTURES = %w[ deploy_with_every_proxy_option deploy_with_on_demand_tls ].freeze

  test "every proxy deploy option has a recorded layering disposition" do
    undecided = emitted_keys - DISPOSITIONS.keys

    assert_empty undecided, <<~MESSAGE
      These deploy options have no layering disposition:

      #{undecided.map { |key| "  --#{key}" }.join("\n")}

      Decide where each one lives when the load balancer fronts the per-host
      proxies, and record it in Dash::Configuration::Proxy::DEPLOY_OPTION_DISPOSITIONS:

        :edge    — TLS, access control, affinity, caching: only where clients connect
        :per_app — headers, rewrites, sleep, compress: only next to the app
        :both    — pool tuning, timeouts: each layer has its own copy, on purpose

      "Both" is a decision too — an option that lands on both layers by
      accident is how session affinity broke in the only topology where it
      mattered.
    MESSAGE
  end

  test "no disposition names an option the gem no longer emits" do
    stale = DISPOSITIONS.keys - emitted_keys

    assert_empty stale, <<~MESSAGE
      These dispositions name deploy options the maximal fixtures no longer emit:

      #{stale.map { |key| "  --#{key}" }.join("\n")}

      Either the option was removed (drop the disposition) or it is no longer
      set in test/fixtures/#{MAXIMAL_FIXTURES.first}.yml — a key that emits
      nothing there is a key this canary cannot guard.
    MESSAGE
  end

  test "deploy_options refuses a key with no disposition" do
    error = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration::Proxy.disposition(:"not-a-real-deploy-option")
    end

    assert_match "no layering disposition", error.message
  end

  # The three layers partition the surface: the per-app proxy behind a load
  # balancer and the load balancer itself must between them emit every decided
  # option exactly once, except the deliberate :both group.
  test "per-app and load balancer surfaces reunite into the full surface" do
    config = maximal_configs.first
    proxy = config.role(:web).proxy
    proxy.stubs(:load_balancing?).returns(true)

    loadbalancer = Dash::Configuration::Loadbalancer.new \
      config: config, proxy_config: proxy.proxy_config, secrets: config.secrets

    per_app = proxy.deploy_options.keys
    edge = loadbalancer.deploy_options.keys
    full = proxy.all_deploy_options.keys

    assert_equal full.sort, (per_app | edge).sort
    assert_equal full.select { |key| DISPOSITIONS[key] == :both }.sort, (per_app & edge).sort
  end

  private
    def emitted_keys
      maximal_configs.flat_map { |config| config.role(:web).proxy.all_deploy_options.keys }.uniq
    end

    def maximal_configs
      @maximal_configs ||= MAXIMAL_FIXTURES.map do |fixture|
        Dash::Configuration.create_from \
          config_file: Pathname.new(File.expand_path("fixtures/#{fixture}.yml", __dir__))
      end
    end
end
