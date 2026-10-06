require_relative "diagnostics_test_case"

class DiagnosticsDriftTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "a consistent fleet has no drift" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_equal({ consistent: true, lock_held: nil, drift: [], unread: [] }, drift.to_h.except(:generated_at))
  end

  test "proxy_target_not_running when the proxy routes to a container that is not running" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1", state: "exited") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_equal [ { code: "proxy_target_not_running", host: "1.1.1.1", role: "web", detail: "app-web routes to aaaaaaaaaaaa, which is not a running container" } ], drift.entries
  end

  test "running_not_targeted per replica slot" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1"), web("cccccccccccc1", name: "app-web.2-999", replica: 2) ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_equal [ { code: "running_not_targeted", host: "1.1.1.1", role: "web", detail: "app-web.2-999 (replica 2) runs but app-web does not route to it" } ], drift.entries
  end

  test "rollout targets count as targeted" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1"), web("cccccccccccc1") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => { "targets" => [ "aaaaaaaaaaaa:80" ], "rollout_targets" => [ "cccccccccccc:80" ] }, "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_empty drift.entries
  end

  test "an unreachable host is not compared, and the snapshot says which hosts went unread" do
    drift = drift_for(containers: { "1.1.1.1" => :error, "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => :error })

    assert_empty drift.entries
    assert_equal [ { host: "1.1.1.1", source: "containers", error: "down" }, { host: "1.1.1.2", source: "proxy_services", error: "down" } ], drift.unread
    assert_equal false, drift.to_h[:consistent]
  end

  test "loadbalancer_target_missing and loadbalancer_target_extra" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] },
      loadbalancer: { host: "lb.example.com", services: { "app" => { "targets" => [ "1.1.1.1:80", "9.9.9.9:80" ] } } })

    assert_equal [
      { code: "loadbalancer_target_missing", host: "lb.example.com", role: nil, detail: "the load balancer does not forward to 1.1.1.2" },
      { code: "loadbalancer_target_extra", host: "lb.example.com", role: nil, detail: "the load balancer forwards to 9.9.9.9, which no proxied role runs on" }
    ], drift.entries
  end

  test "version_mismatch and multiple_running_versions" do
    drift = drift_for(containers: {
      "1.1.1.1" => [ web("aaaaaaaaaaaa1"), web("dddddddddddd1", name: "app-web-998", version: "998") ],
      "1.1.1.2" => [ web("bbbbbbbbbbbb1", name: "app-web-998", version: "998") ]
    }, services: { "1.1.1.1" => [ "aaaaaaaaaaaa", "dddddddddddd" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_equal [
      { code: "multiple_running_versions", host: "1.1.1.1", role: "web", detail: "web runs 998, 999 on 1.1.1.1" },
      { code: "version_mismatch", host: nil, role: "web", detail: "web runs 998+999 on 1.1.1.1, 998 on 1.1.1.2" }
    ], drift.entries
  end

  test "a renamed-out-of-the-way container runs the version it was named for" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1", version: "999_replaced_0123456789abcdef") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] })

    assert_empty drift.entries
  end

  test "version codes wait while the deploy lock is held" do
    drift = drift_for(containers: { "1.1.1.1" => [ web("aaaaaaaaaaaa1") ], "1.1.1.2" => [ web("bbbbbbbbbbbb1", version: "998") ] },
      services: { "1.1.1.1" => [ "aaaaaaaaaaaa" ], "1.1.1.2" => [ "bbbbbbbbbbbb" ] }, lock: { lock: { host: "1.1.1.1", held: true } })

    assert_empty drift.entries
    assert_equal true, drift.to_h[:lock_held]
  end

  test "take captures the three snapshots it compares" do
    Dash::Diagnostics::Containers.expects(:new).with(accessories: []).returns(stub(to_h: { hosts: [] }))
    Dash::Diagnostics::ProxyServices.any_instance.expects(:to_h).returns(hosts: [])
    Dash::Diagnostics::Lock.any_instance.expects(:to_h).returns(lock: { held: false })

    assert Dash::Diagnostics::Drift.take.to_h[:consistent]
  end

  private
    def drift_for(containers:, services:, loadbalancer: nil, lock: nil)
      Dash::Diagnostics::Drift.new(
        containers: { hosts: containers.map { |host, list| list == :error ? { host: host, error: "down" } : { host: host, containers: list } } },
        proxy_services: { hosts: services.map { |host, targets| proxy_host(host, targets) }, loadbalancer: loadbalancer },
        lock: lock)
    end

    def proxy_host(host, targets)
      return { host: host, error: "down" } if targets == :error

      service = targets.is_a?(Hash) ? targets : { "targets" => targets.map { |id| "#{id}:80" } }
      { host: host, services: { "app-web" => service } }
    end

    def web(id, name: "app-web-999", version: "999", replica: 1, state: "running")
      { name: name, id: id, role: "web", replica: replica, version: version, state: state }
    end
end
