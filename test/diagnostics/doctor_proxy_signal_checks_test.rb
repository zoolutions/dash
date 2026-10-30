require_relative "diagnostics_test_case"

# web: a proxy signal on 1.1.1.1 and 1.1.1.2.
class DiagnosticsDoctorProxySignalChecksTest < DiagnosticsTestCase
  BOUNDS = [ 10.0, 25.0, 50.0, 100.0 ]

  setup do
    configure :deploy_with_scale_proxy_signal
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
    Socket.stubs(:gethostname).returns("laptop")
  end

  test "the fleet p95 with the traffic it was read from, when the app reports its queue time" do
    queue host("1.1.1.1", requests: 30, app: 30), host("1.1.1.2", requests: 10, app: 10)

    assert_equal :ok, check.status
    assert_match %r{\Aproxy answered 9\.5ms \(p95 of 40 requests over 60s on 2 hosts\) in [\d.]+ms, from this machine \(laptop\)\z}, check.detail
  end

  test "no requests in the window is a queue time of zero" do
    queue host("1.1.1.1", requests: 0), host("1.1.1.2", requests: 0)

    assert_equal :ok, check.status
    assert_match %r{\Aproxy answered 0\.0ms \(no requests in the last 60s\) in [\d.]+ms, from this machine \(laptop\)\z}, check.detail
  end

  test "a host whose dash-proxy cannot be read warns, naming it" do
    queue host("1.1.1.1", requests: 5, app: 5), { host: "1.1.1.2", error: "Errno::ECONNREFUSED: Connection refused" }

    assert_equal :warn, check.status
    assert_match %r{\(p95 of 5 requests over 60s on 1 host\) .*; 1\.1\.1\.2 did not answer: Errno::ECONNREFUSED: Connection refused\z}, check.detail
  end

  test "queue time measured only as the proxy's connection wait, with no max_conns, warns: it reads near zero whatever the backlog" do
    queue host("1.1.1.1", requests: 5, proxy: 5), host("1.1.1.2", requests: 5, proxy: 5)

    assert_equal :warn, check.status
    assert_match %r{; every request was timed by dash-proxy's wait for a connection, which stays near 0 without proxy/target/max_conns: send Server-Timing: queue;dur=<ms> from the app or set max_conns to its thread count \(dash docs role\)\z}, check.detail
  end

  test "the connection wait is a real queue time once max_conns caps the connections" do
    queue host("1.1.1.1", requests: 5, proxy: 5), host("1.1.1.2", requests: 5, proxy: 5)
    DASH.config.role(:web).proxy.stubs(:target_max_conns).returns(5)

    assert_equal :ok, check.status
  end

  test "no host answering fails" do
    queue({ host: "1.1.1.1", error: "no answer" }, { host: "1.1.1.2", error: "no answer" })

    assert_equal :fail, check.status
    assert_equal "proxy did not answer from this machine (laptop): RuntimeError: no dash-proxy of web answered: 1.1.1.1 (no answer), 1.1.1.2 (no answer)", check.detail
  end

  test "reads no Redis, Postgres or Prometheus: the connections are never used" do
    queue host("1.1.1.1", requests: 1, app: 1)
    connections = Dash::Autoscale::Connections.new
    Dash::Autoscale::Connections.stubs(:new).returns(connections)
    connections.expects(:with).never

    check
  end

  private
    def queue(*hosts)
      Dash::Diagnostics::ProxyQueue.any_instance.stubs(:to_h).returns({ role: "web", hosts: hosts })
    end

    def host(name, requests:, app: 0, proxy: 0)
      { host: name, targets: [ { address: "#{name}:80", slot: "active", state: "healthy", in_flight: 0, window_seconds: 60, requests: requests,
        p95_ms: 9.5, max_ms: 9.9, app: app, proxy: proxy, buckets: BOUNDS.zip([ requests ] * 4) } ] }
    end

    def check
      Dash::Diagnostics::Doctor::SignalChecks.new.run.find { |result| result.target == "web" }
    end
end
