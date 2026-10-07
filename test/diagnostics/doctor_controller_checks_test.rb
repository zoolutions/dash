require_relative "diagnostics_test_case"

class DiagnosticsDoctorControllerChecksTest < DiagnosticsTestCase
  NOW = Time.utc(2026, 10, 14, 21, 0)

  setup do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).returns("")
  end

  test "no role with a schedule, no controller check" do
    configure "deploy_with_scale"

    assert_empty checks.run
  end

  test "a running controller is ok" do
    configure "deploy_with_scale_schedule"
    stub_state "heartbeat.json", heartbeat(last_tick_at: (NOW - 4).iso8601).to_json

    assert_equal [ [ "1.1.1.1", :ok, "controller abc on ops-1 (dash 3.9.0) ticked 4s ago, for payments, reports" ] ], results
  end

  test "no controller, a stale one, or a stopped one warns" do
    configure "deploy_with_scale_schedule"

    assert_equal [ [ "1.1.1.1", :warn, "no controller has run; payments, reports have a schedule that only dash autoscale run carries out" ] ], results

    stub_state "heartbeat.json", heartbeat(last_tick_at: (NOW - 120).iso8601).to_json
    assert_equal [ [ "1.1.1.1", :warn, "controller abc on ops-1 last ticked 120s ago (interval 10s), it looks stopped or stuck" ] ], results

    stub_state "heartbeat.json", heartbeat(last_tick_at: (NOW - 120).iso8601, stopped_at: (NOW - 100).iso8601).to_json
    assert_equal [ [ "1.1.1.1", :warn, "controller abc on ops-1 stopped at #{(NOW - 100).iso8601}" ] ], results
  end

  test "a paused role warns with when it resumes" do
    configure "deploy_with_scale_schedule"
    stub_state "heartbeat.json", heartbeat(last_tick_at: (NOW - 4).iso8601).to_json
    stub_state "grep -H", ".dash/apps/app/autoscale/pause/payments.json:#{{ "until" => (NOW + 60).iso8601, "by" => "Jane" }.to_json}\n"

    assert_includes results, [ "payments", :warn, "paused by Jane until #{(NOW + 60).iso8601}" ]
  end

  test "a state host that does not answer warns, never crashes" do
    configure "deploy_with_scale_schedule"
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).raises(Errno::ECONNREFUSED)

    status, detail = results.first.drop(1)
    assert_equal :warn, status
    assert_match "could not read the controller heartbeat", detail
  end

  test "is part of the doctor, titled Controller" do
    configure "deploy_with_scale_schedule"

    assert_equal "Controller", Dash::Diagnostics::Doctor::Result.new(:controller, "1.1.1.1", :ok, "").title
    Dash::Diagnostics::Doctor::ControllerChecks.any_instance.expects(:run).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:host_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:endpoint_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:pool_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:drift_check_results).returns([])
    Dash::Diagnostics::Doctor.new(registry: false).run
  end

  private
    def checks
      Dash::Diagnostics::Doctor::ControllerChecks.new(now: NOW)
    end

    def results
      checks.run.map { |result| [ result.target, result.status, result.detail ] }
    end

    def stub_state(fragment, output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture).with { |*args| args.join(" ").include?(fragment) }.returns(output)
    end

    def heartbeat(**fields)
      { "controller_id" => "abc", "hostname" => "ops-1", "pid" => 42, "version" => "3.9.0", "mode" => "loop", "interval" => 10 }.merge(fields.transform_keys(&:to_s))
    end
end
