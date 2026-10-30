require_relative "diagnostics_test_case"
require_relative "proxy_queue_fixtures"

# web: a proxy signal on 1.1.1.1 and 1.1.1.2, whose dash-proxy routes it as app-web.
class DiagnosticsProxyQueueTest < DiagnosticsTestCase
  include ProxyQueueFixtures

  setup do
    configure :deploy_with_scale_proxy_signal
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
  end

  test "each host's queue window for the role's service, other services left out" do
    stub_capture "1.1.1.1", "dash-proxy list --json", list("app-web" => [ target("aaa:80", requests: 4, cumulative: [ 1, 3, 4, 4 ], app: 4) ],
      "other-app-web" => [ target("zzz:80", requests: 9, cumulative: [ 9, 9, 9, 9 ]) ])
    stub_capture "1.1.1.2", "dash-proxy list --json", list("app-web" => [ target("bbb:80", requests: 2, cumulative: [ 0, 0, 1, 2 ], proxy: 2, slot: "rollout") ])

    snapshot = queue

    assert_equal "web", snapshot[:role]
    assert_equal [ "1.1.1.1", "1.1.1.2" ], snapshot[:hosts].map { |host| host[:host] }
    assert_equal({ address: "aaa:80", slot: "active", state: "healthy", in_flight: 1, window_seconds: 60, requests: 4, p95_ms: 9.5, max_ms: 20.0, app: 4, proxy: 0,
      buckets: BOUNDS.zip([ 1, 3, 4, 4 ]) }, snapshot[:hosts].first[:targets].first)
    assert_equal [ [ "bbb:80", "rollout", 2 ] ], snapshot[:hosts].last[:targets].map { |target| target.values_at(:address, :slot, :proxy) }
  end

  test "a host that cannot be read, or whose proxy does not route the role, is that host's error" do
    stub_unreachable "1.1.1.1", "dash-proxy list --json"
    stub_capture "1.1.1.2", "dash-proxy list --json", list("other-app-web" => [])

    hosts = queue[:hosts]

    assert_match "ECONNREFUSED", hosts.first[:error]
    assert_equal "RuntimeError: dash-proxy on 1.1.1.2 routes no app-web", hosts.last[:error]
  end

  test "a proxy older than v1.1.0.5 reports no queue window" do
    stub_capture "1.1.1.1", "dash-proxy list --json", { services: { "app-web" => { targets: [ "aaa:80" ] } } }.to_json
    stub_capture "1.1.1.2", "dash-proxy list --json", list("app-web" => [])

    hosts = queue[:hosts]

    assert_equal "RuntimeError: dash-proxy on 1.1.1.1 reports no queue window (it predates v1.1.0.5), run dash proxy reboot", hosts.first[:error]
    assert_equal [], hosts.last[:targets]
  end

  test "a current proxy routing the role with no targets omits both lists: no targets, not an old proxy" do
    stub_capture "1.1.1.1", "dash-proxy list --json", list("app-web" => [])
    stub_capture "1.1.1.2", "dash-proxy list --json", { services: { "app-web" => { host: "app.example.com" } } }.to_json

    assert_equal [ [], [] ], queue[:hosts].map { |host| host[:targets] }
  end

  test "parses a real `list --json` for one service, as the integration test feeds it" do
    output = list("app-web" => [ target("aaa:80", requests: 3, cumulative: [ 3, 3, 3, 3 ]) ])

    assert_equal [ "aaa:80" ], Dash::Diagnostics::ProxyQueue.targets(output, service: "app-web", host: "vm1").map { |target| target[:address] }
  end

  private
    def queue
      Dash::Diagnostics::ProxyQueue.new(role: DASH.config.role(:web)).to_h
    end
end
