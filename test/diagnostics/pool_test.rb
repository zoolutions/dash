require_relative "diagnostics_test_case"

class DiagnosticsPoolTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_scale
  end

  test "per scaled role its provider and members, with the version each started member runs" do
    stub_members member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "stopped")
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", "app-payments-abc\tUp 2 hours\napp-payments.2-abc\tUp 1 hour\n"

    payments = Dash::Diagnostics::Pool.new.to_h[:roles].first

    assert_equal({ role: "payments", provider: "upcloud", members: "power", min: 1, max: 3, baseline: [ "1.1.1.2" ] }, payments.except(:pool))
    assert_equal [
      { id: "m1", host: "10.0.0.22", state: "started", labels: { "dash.role" => "payments" }, verified: true, versions: [ "abc" ], orphan: false },
      { id: "m2", host: "10.0.0.23", state: "stopped", labels: { "dash.role" => "payments" }, verified: true, versions: [], orphan: false }
    ], payments[:pool]
  end

  test "a started member running nothing of the role is an orphan" do
    stub_members member("m1", "10.0.0.22", "started")
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", ""

    assert Dash::Diagnostics::Pool.new.to_h[:roles].first[:pool].first[:orphan]
  end

  test "a member that cannot be read is not called an orphan" do
    stub_members member("m1", "10.0.0.22", "started")
    stub_unreachable "10.0.0.22", "{{.Names}}\\t{{.Status}}"

    entry = Dash::Diagnostics::Pool.new.to_h[:roles].first[:pool].first
    assert_equal false, entry[:orphan]
    assert_match "ECONNREFUSED", entry[:error]
  end

  test "a provider that does not answer is the role's error, not a crash" do
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "upcloud: GET /1.3/server answered 401")

    payments = Dash::Diagnostics::Pool.new.to_h[:roles].first
    assert_equal "Could not read the payments pool: upcloud: GET /1.3/server answered 401", payments[:error]
    assert_nil payments[:pool]
  end

  test "keeps to the run's --hosts" do
    stub_members member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "started")
    DASH.specific_hosts = [ "1.1.1.2", "10.0.0.22" ]
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", "app-payments-abc\tUp\n"

    payments = Dash::Diagnostics::Pool.new.to_h[:roles].first
    assert_equal [ "m1" ], payments[:pool].map { |entry| entry[:id] }
    assert_equal [ "1.1.1.2" ], payments[:baseline]
  end

  test "another role's provider outage does not error this role's pool" do
    configure :deploy_with_scale
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == "payments" }.returns([ member("m1", "10.0.0.22", "started") ])
    DASH.stubs(:hosts).raises(Dash::Autoscale::ProviderError, "another role's pool is down")
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", "app-payments-abc\tUp\n"

    payments = Dash::Diagnostics::Pool.new.to_h[:roles].first
    assert_nil payments[:error]
    assert_equal [ "abc" ], payments[:pool].first[:versions]
  end

  test "an unscaled configuration has no pool" do
    configure :deploy_simple

    assert_equal [], Dash::Diagnostics::Pool.new.to_h[:roles]
  end

  private
    def stub_members(*members)
      Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns(members)
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: "payments", state: state, labels: { "dash.role" => "payments" })
    end
end
