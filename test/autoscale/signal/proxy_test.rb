require "test_helper"
require_relative "fakes"

class AutoscaleSignalProxyTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)
  BOUNDS = [ 10.0, 25.0, 50.0, 100.0 ]

  test "the fleet p95 in milliseconds, from every target of the role on every host merged" do
    sample = reader(host("1.1.1.1", target(10, [ 10, 10, 10, 10 ], app: 10)),
      host("1.1.1.2", target(6, [ 0, 0, 0, 6 ], app: 6), target(4, [ 0, 0, 0, 4 ], proxy: 4))).sample(at: NOW)

    assert_equal 95.0, sample.value # rank 19 of 20 is 9 of 10 into (50, 100]
    assert_nil sample.error
    assert_equal({ unit: "ms", window_seconds: 60, requests: 20, measured_by: { app: 16, proxy: 4 },
      hosts: [ { host: "1.1.1.1", targets: 1, requests: 10, p95_ms: 9.5 }, { host: "1.1.1.2", targets: 2, requests: 10, p95_ms: 97.5 } ] }, sample.detail)
  end

  test "no requests in the window is a queue time of zero, not a missing sample: an idle role can scale in" do
    sample = reader(host("1.1.1.1", target(0, [ 0, 0, 0, 0 ])), host("1.1.1.2")).sample(at: NOW)

    assert_equal 0.0, sample.value
    assert_not sample.missing?
    assert_equal 0, sample.detail[:requests]
  end

  test "a host that cannot be read is named, and the rest still answer" do
    sample = reader(host("1.1.1.1", target(2, [ 2, 2, 2, 2 ])), { host: "1.1.1.2", error: "Errno::ECONNREFUSED: Connection refused" }).sample(at: NOW)

    assert_equal 9.5, sample.value
    assert_equal({ host: "1.1.1.2", error: "Errno::ECONNREFUSED: Connection refused" }, sample.detail[:hosts].last)
  end

  test "no host answering is a missing sample that names them" do
    sample = reader({ host: "1.1.1.1", error: "Errno::ECONNREFUSED: Connection refused" }, { host: "1.1.1.2", error: "no answer" }).sample(at: NOW)

    assert sample.missing?
    assert_equal "RuntimeError: no dash-proxy of web answered: 1.1.1.1 (Errno::ECONNREFUSED: Connection refused), 1.1.1.2 (no answer)", sample.error
    assert_equal [ "1.1.1.1", "1.1.1.2" ], sample.detail[:hosts].map { |host| host[:host] }
  end

  test "Signal.for hands the reader its role, and it has no busy count" do
    role = stub(name: "web", scale: stub(signal: signal))
    reader = Dash::Autoscale::Signal.for(role, AutoscaleSignalFakes::Connections.new)

    assert_kind_of Dash::Autoscale::Signal::Proxy, reader
    assert_equal role, reader.role
    assert_not reader.busy?
  end

  test "the detail rides in the sample's hash, so a decision and a record carry it" do
    sample = reader(host("1.1.1.1", target(1, [ 1, 1, 1, 1 ]))).sample(at: NOW)

    assert_equal sample.detail, sample.to_h[:detail]
    assert_not Dash::Autoscale::Sample.new(value: 1, at: NOW).to_h.key?(:detail)
  end

  private
    def reader(*hosts)
      role = stub(name: "web")
      queue = { role: "web", hosts: hosts }

      Dash::Autoscale::Signal::Proxy.new(signal, AutoscaleSignalFakes::Connections.new, role: role, queue: ->(given) { given == role ? queue : flunk("another role") })
    end

    def signal
      Dash::Configuration::Role::Scale::Signal.new(signal_config: { "source" => "proxy" }, context: "test")
    end

    def host(name, *targets)
      { host: name, targets: targets }
    end

    def target(requests, cumulative, app: 0, proxy: 0)
      { address: "x:80", slot: "active", state: "healthy", in_flight: 0, window_seconds: 60, requests: requests,
        p95_ms: 9.5, max_ms: 20.0, app: app, proxy: proxy, buckets: BOUNDS.zip(cumulative) }
    end
end
