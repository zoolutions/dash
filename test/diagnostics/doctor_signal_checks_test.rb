require_relative "diagnostics_test_case"
require_relative "../autoscale/signal/fakes"

# payments: a Sidekiq signal and a Postgres guard above 180. reports: a schedule only.
class DiagnosticsDoctorSignalChecksTest < DiagnosticsTestCase
  GUARD = "SELECT count(*) FROM pg_stat_activity"

  setup do
    configure :deploy_with_scale_signal
    Socket.stubs(:gethostname).returns("laptop")
    sources redis: AutoscaleSignalFakes::Redis.new([ "LINDEX", "queue:payments", -1 ] => nil), postgres: AutoscaleSignalFakes::Postgres.new(GUARD => "4")
  end

  test "no role with a signal, no signal check" do
    configure :deploy_with_scale_schedule

    assert_empty checks
  end

  test "keeps to the run's --roles" do
    DASH.specific_roles = [ "web", "reports" ]

    assert_empty checks
  end

  test "a source and a guard that answer are ok, with the value, the latency and where it ran" do
    assert_equal [ [ :signal, "payments", :ok ], [ :signal, "payments hold_when/0", :ok ] ], checks.map { |result| [ result.check, result.target, result.status ] }
    assert_match %r{\Asidekiq answered 0 in [\d.]+ms, from this machine \(laptop\)\z}, checks.first.detail
    assert_match %r{\Apostgres answered 4\.0 in [\d.]+ms, from this machine \(laptop\)\z}, checks.last.detail
    assert_equal "Signals", checks.first.title
  end

  test "a source that does not answer fails, naming the error and where it was asked from" do
    sources redis: Errno::ECONNREFUSED.new("cache.internal:6379"), postgres: Dash::ConfigurationError.new("autoscale/postgres: needs the pg gem")

    assert_equal [ [ "payments", :fail, "sidekiq did not answer from this machine (laptop): Errno::ECONNREFUSED: Connection refused - cache.internal:6379" ],
      [ "payments hold_when/0", :fail, "postgres did not answer from this machine (laptop): Dash::ConfigurationError: autoscale/postgres: needs the pg gem" ] ],
      checks.map { |result| [ result.target, result.status, result.detail ] }
  end

  test "an answer without a number, and a guard holding a scale-out, warn" do
    sources prometheus: AutoscaleSignalFakes::Prometheus.new("max(x)" => nil), postgres: AutoscaleSignalFakes::Postgres.new(GUARD => "195")
    DASH.config.role(:payments).scale.signal.stubs(:source).returns("prometheus")
    DASH.config.role(:payments).scale.signal.stubs(:query).returns("max(x)")

    assert_equal [ :warn, :warn ], checks.map(&:status)
    assert_match %r{\Aprometheus answered with no value in [\d.]+ms, from this machine \(laptop\)\z}, checks.first.detail
    assert_match %r{\Apostgres answered 195\.0 in [\d.]+ms, from this machine \(laptop\); above 180, so it holds a scale-out\z}, checks.last.detail
  end

  test "the doctor runs it" do
    Dash::Diagnostics::Doctor.any_instance.stubs(:host_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:endpoint_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:pool_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:controller_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:drift_check_results).returns([])

    assert_includes Dash::Diagnostics::Doctor.new.run.map(&:check), :signal
  end

  test "a check that cannot run at all warns instead of failing the doctor" do
    Dash::Diagnostics::Doctor::SignalChecks.any_instance.stubs(:run).raises(RuntimeError, "boom")
    Dash::Diagnostics::Doctor.any_instance.stubs(:host_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:endpoint_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:pool_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:controller_check_results).returns([])
    Dash::Diagnostics::Doctor.any_instance.stubs(:drift_check_results).returns([])

    signal = Dash::Diagnostics::Doctor.new.run.find { |result| result.check == :signal }
    assert_equal [ :warn, "could not check the autoscale signals (RuntimeError: boom)" ], [ signal.status, signal.detail ]
  end

  private
    def sources(**clients)
      Dash::Autoscale::Connections.stubs(:new).returns(AutoscaleSignalFakes::Connections.new(**clients))
    end

    def checks
      Dash::Diagnostics::Doctor::SignalChecks.new.run
    end
end
