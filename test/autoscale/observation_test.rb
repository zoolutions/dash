require_relative "../diagnostics/diagnostics_test_case"

class AutoscaleObservationTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_scale_schedule
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([
      Dash::Autoscale::Member.new(id: "m1", host: "10.0.0.22", role: "payments", state: "started"),
      Dash::Autoscale::Member.new(id: "m2", host: "10.0.0.23", role: "payments", state: "stopped")
    ])
  end

  test "counts the containers running on the baseline and the started members" do
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\napp-payments.2-123\tUp\napp-payments.3-123\tUp\n"
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\n"

    observation = Dash::Autoscale::Observation.take(payments)

    assert_equal 4, observation.current
    assert_equal [ "m1" ], observation.members.map(&:id)
    assert_equal [ "m1", "m2" ], observation.pool.map(&:id)
    assert_equal [ "10.0.0.22" ], observation.member_hosts
    assert_equal({}, observation.unreadable_baseline)
    assert_equal({}, observation.unreachable_members)
    assert_nil observation.pool_error
  end

  test "a member that does not answer is unreachable; the rest still count" do
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\n"
    stub_unreachable "10.0.0.22", "{{.Names}}\\t{{.Status}}"

    observation = Dash::Autoscale::Observation.take(payments)

    assert_equal 1, observation.current
    assert_equal [ "10.0.0.22" ], observation.unreachable_members.keys
    assert_match "ECONNREFUSED", observation.unreachable_members["10.0.0.22"]
    assert_equal({}, observation.unreadable_baseline)
  end

  test "a baseline host that does not answer is unreadable baseline, never a member to replace" do
    stub_unreachable "1.1.1.2", "{{.Names}}\\t{{.Status}}"
    stub_capture "10.0.0.22", "{{.Names}}\\t{{.Status}}", ""

    observation = Dash::Autoscale::Observation.take(payments)

    assert_equal [ "1.1.1.2" ], observation.unreadable_baseline.keys
    assert_equal({}, observation.unreachable_members)
  end

  test "a pool that cannot be read is the pool error" do
    Dash::Autoscale::Pool.any_instance.unstub(:members_for)
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")

    observation = Dash::Autoscale::Observation.take(payments)

    assert_equal "Could not read the payments pool: down", observation.pool_error
    assert_nil observation.current
    assert_equal [], observation.members
  end

  private
    def payments
      DASH.config.role(:payments)
    end
end
