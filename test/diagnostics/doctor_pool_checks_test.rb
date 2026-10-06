require_relative "diagnostics_test_case"

class DiagnosticsDoctorPoolChecksTest < DiagnosticsTestCase
  test "an unscaled configuration has no pool checks" do
    configure "deploy_simple"

    assert_empty Dash::Diagnostics::Doctor::PoolChecks.new.run
  end

  test "a power role with enough members, one of them stuck" do
    configure "deploy_with_scale"
    stub_members member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "maintenance")

    assert_equal [
      [ "payments", :ok, "upcloud answered: 2 members, 1 started" ],
      [ "payments", :ok, "2 members for the 2 it can scale out to (max 3 hosts)" ],
      [ "payments m2", :warn, "member 10.0.0.23 is maintenance, dash leaves it alone until it is started or stopped" ]
    ], results
  end

  test "a power role short of members warns with the labels to set" do
    configure "deploy_with_scale"
    stub_members member("m1", "10.0.0.22", "stopped")

    assert_includes results, [ "payments", :warn, "1 of the 2 members max 3 needs carry its labels " \
      "(dash.service=app, dash.destination=-, dash.role=payments); it cannot scale past 2 hosts" ]
  end

  test "a provider that does not answer fails the role" do
    configure "deploy_with_scale"
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "upcloud: GET /1.3/server answered 401 AUTHENTICATION_FAILED")

    assert_equal [ [ "payments", :fail, "Could not read the payments pool from upcloud: upcloud: GET /1.3/server answered 401 AUTHENTICATION_FAILED" ] ], results
  end

  test "a scaled web role reports its load balancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    configure "deploy_with_scale_web"
    stub_members

    assert_includes results, [ "web", :ok, "load balanced by 1.1.1.1" ]
  end

  test "the doctor survives a provider that does not answer" do
    configure "deploy_with_scale"
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")
    Dash::Diagnostics::Doctor::EndpointChecks.any_instance.stubs(:run).returns([])
    Dash::Diagnostics::Doctor::ConfigChecks.any_instance.stubs(:run).returns([])

    doctor = Dash::Diagnostics::Doctor.new(registry: false)
    doctor.run

    assert_not doctor.successful?
    assert_equal [ [ :ssh, "pool" ], [ :pool, "payments" ] ], doctor.failures.map { |result| [ result.check, result.target ] }
    assert_equal [ :drift ], doctor.warnings.map(&:check)
    assert_equal "Pool", doctor.failures[1].title
  end

  private
    def results
      Dash::Diagnostics::Doctor::PoolChecks.new.run.map { |result| [ result.target, result.status, result.detail ] }
    end

    def stub_members(*members)
      Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns(members)
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: "payments", state: state)
    end
end
