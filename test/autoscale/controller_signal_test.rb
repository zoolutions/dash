require_relative "../diagnostics/diagnostics_test_case"
require_relative "controller_fakes"

# payments: no schedule, a Sidekiq signal held between 2 and 10 seconds (up after 30s, down
# after 10m), step 2, cooldown up 60 / down 600, a Postgres guard above 180, replicas 1-3 on
# 1 to 3 hosts. reports: a weekday-morning schedule and no signal.
class AutoscaleControllerSignalTest < DiagnosticsTestCase
  include AutoscaleControllerFakes

  QUIET = Time.utc(2026, 10, 17, 12, 0) # a Saturday: no reports window

  setup do
    configure :deploy_with_scale_signal
    @store = FakeStore.new
    Dash::Autoscale::StateStore.stubs(:new).returns(@store)
    @cli = FakeCli.new(Pathname.new(File.expand_path("../fixtures/deploy_with_scale_signal.yml", __dir__)))
    @reader = FakeReader.new
    @members = [ member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "stopped") ]
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == "payments" }.returns(@members)
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == "reports" }.returns([])
    observe "payments", current: 2
    observe "reports", current: 1
  end

  test "a role with a signal and no schedule is the controller's" do
    assert_equal [ "payments", "reports" ], start.roles.map(&:name)
  end

  test "sustained load scales out by a step once up.for has passed" do
    controller = start
    @reader.value = 20

    tick(controller, QUIET)
    assert_empty @cli.scale_sets
    assert_equal QUIET.iso8601, @store.state.dig("roles", "payments", "above_since")

    tick(controller, QUIET + 30)
    assert_equal [ [ "payments", 4 ] ], @cli.scale_sets
  end

  test "a burst shorter than up.for does not" do
    controller = start
    @reader.value = 20
    tick(controller, QUIET)
    @reader.value = 5
    tick(controller, QUIET + 10)
    @reader.value = 20
    tick(controller, QUIET + 30)

    assert_empty @cli.scale_sets
    assert_equal (QUIET + 30).iso8601, @store.state.dig("roles", "payments", "above_since"), "the window started over"
  end

  test "a guard above its bound holds the scale-out" do
    controller = start
    @reader.value = 20
    @reader.guard_value = 250

    tick(controller, QUIET)
    decisions = tick(controller, QUIET + 60)

    assert_empty @cli.scale_sets
    assert_equal [ "held_by_guard" ], decisions.find { |decision| decision.role == "payments" }.reasons
  end

  test "inside the band it holds, above its floor" do
    observe "payments", current: 4
    controller = start
    @reader.value = 5

    tick(controller, QUIET)
    tick(controller, QUIET + 3600)

    assert_empty @cli.scale_sets
  end

  test "a quiet period scales in by a step after down.for" do
    observe "payments", current: 5
    controller = start
    @reader.value = 0.5

    tick(controller, QUIET)
    tick(controller, QUIET + 300)
    assert_empty @cli.scale_sets

    tick(controller, QUIET + 600)
    assert_equal [ [ "payments", 3 ] ], @cli.scale_sets
  end

  test "separate --once runs keep the breach window in state.json" do
    @reader.value = 20
    first = start(now: QUIET)
    tick(first, QUIET)
    first.release

    second = start(now: QUIET + 30)
    tick(second, QUIET + 30)

    assert_equal [ [ "payments", 4 ] ], @cli.scale_sets
  end

  test "a signal that cannot be read holds the role and the tick goes on" do
    controller = start
    @reader.error = "RuntimeError: Connection refused"

    decisions = tick(controller, QUIET)

    payments = decisions.find { |decision| decision.role == "payments" }
    assert_equal [ "hold", [ "missing_data" ] ], [ payments.action, payments.reasons ]
    assert_equal "signal sidekiq: RuntimeError: Connection refused", payments.error
    assert_equal QUIET.iso8601, @store.heartbeat["last_tick_at"]
  end

  test "a reader that raises fails only its role's evaluation" do
    controller = start
    @reader.raises = Dash::ConfigurationError.new("autoscale/redis: needs the redis-client gem")

    decisions = tick(controller, QUIET)

    payments = decisions.find { |decision| decision.role == "payments" }
    assert_equal [ "action_failed" ], payments.reasons
    assert_match "needs the redis-client gem", payments.error
    assert_equal [ "at_target" ], decisions.find { |decision| decision.role == "reports" }.reasons
  end

  test "the decision log and the metrics carry the signal and the guards" do
    controller = start
    @reader.value = 20

    tick(controller, QUIET)

    logged = @store.decisions.find { |decision| decision["role"] == "payments" }
    assert_equal({ "source" => "sidekiq", "value" => 20, "at" => QUIET.iso8601, "error" => nil }, logged.dig("inputs", "signal"))
    assert_equal 0, logged.dig("inputs", "guards", 0, "value")
    assert_match %(dash_autoscale_signal{role="payments",source="sidekiq"} 20), controller.metrics.render
    assert_match %(dash_autoscale_guard{role="payments",guard="0",source="postgres"} 0), controller.metrics.render
  end

  test "a role without a signal is never read" do
    configure :deploy_with_scale_schedule
    @cli = FakeCli.new(Pathname.new(File.expand_path("../fixtures/deploy_with_scale_schedule.yml", __dir__)))
    observe "payments", current: 1
    observe "reports", current: 1

    tick(start, QUIET)

    assert_equal 0, @reader.reads
  end

  test "stopping closes the reader's connections" do
    controller = start

    controller.release

    assert @reader.closed
  end

  private
    def start(now: QUIET)
      Dash::Autoscale::Controller.new(cli: @cli, clock: -> { now }, reader: @reader).tap(&:start)
    end

    def tick(controller, now)
      controller.instance_variable_set(:@clock, -> { now })
      controller.tick
    end

    def observe(role_name, current:)
      Dash::Autoscale::Observation.stubs(:take).with { |role| role.name == role_name }.returns(
        Dash::Autoscale::Observation.new(role: DASH.config.role(role_name), current: current, pool: (role_name == "payments" ? @members : [])))
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: "payments", state: state)
    end
end
