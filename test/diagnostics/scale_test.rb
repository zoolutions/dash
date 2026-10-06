require_relative "diagnostics_test_case"

class DiagnosticsScaleTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_replicas
  end

  test "per role its bounds, its total and each host's replicas, from one docker ps per host" do
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp 2 hours\napp-payments.2-123\tUp 5 minutes (healthy)\n"
    stub_capture "1.1.1.3", "{{.Names}}\\t{{.Status}}", ""

    payments = Dash::Diagnostics::Scale.new(roles: [ DASH.config.role(:payments) ]).to_h[:roles].first

    assert_equal({ role: "payments", min: 1, max: 3, total: 2, unread: [], hosts: {
      "1.1.1.2" => [ { replica: 1, version: "123", status: "Up 2 hours" }, { replica: 2, version: "123", status: "Up 5 minutes (healthy)" } ],
      "1.1.1.3" => [] } }, payments)
  end

  test "an unreachable host is unread, not a crash and not an empty host" do
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp 2 hours\n"
    stub_unreachable "1.1.1.3", "{{.Names}}\\t{{.Status}}"

    payments = Dash::Diagnostics::Scale.new(roles: [ DASH.config.role(:payments) ]).to_h[:roles].first

    assert_equal [ "1.1.1.2" ], payments[:hosts].keys
    assert_equal 1, payments[:total]
    assert_equal "1.1.1.3", payments[:unread].first[:host]
    assert_match "ECONNREFUSED", payments[:unread].first[:error]
  end

  test "a scaled role lists its members, and flags a started one running nothing of the role" do
    configure :deploy_with_scale
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([
      Dash::Autoscale::Member.new(id: "m1", host: "10.0.0.22", role: "payments", state: "started"),
      Dash::Autoscale::Member.new(id: "m2", host: "10.0.0.23", role: "payments", state: "stopped")
    ])
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp 2 hours\n"
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", ""

    payments = Dash::Diagnostics::Scale.new(roles: [ DASH.config.role(:payments) ]).to_h[:roles].first

    assert_equal [ "1.1.1.2", "10.0.0.22" ], payments[:hosts].keys
    assert_equal [ { id: "m1", host: "10.0.0.22", state: "started", orphan: true }, { id: "m2", host: "10.0.0.23", state: "stopped", orphan: false } ], payments[:members]
    assert_equal({ min: 1, max: 3 }, payments[:scale])
  end

  test "a scaled role whose pool cannot be read is an error, not a crash" do
    configure :deploy_with_scale
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")

    payments = Dash::Diagnostics::Scale.new(roles: [ DASH.config.role(:payments) ]).to_h[:roles].first
    assert_equal({ role: "payments", error: "Could not read the payments pool: down" }, payments)
  end

  test "keeps to the hosts in scope" do
    DASH.specific_hosts = [ "1.1.1.2" ]
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", ""

    assert_equal [ "1.1.1.2" ], Dash::Diagnostics::Scale.new(roles: [ DASH.config.role(:payments) ]).to_h[:roles].first[:hosts].keys
  end
end
