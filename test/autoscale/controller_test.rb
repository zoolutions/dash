require_relative "../diagnostics/diagnostics_test_case"

# payments: replicas 1-3 on 1 to 3 hosts, a window from 22:00 on the 14th (Stockholm) for
# 30h asking for 6, boot_timeout 240, warmup 300, cooldown down 600, step 3. reports:
# replicas 1-2 on 1 to 2 hosts, 4 containers on weekday mornings.
class AutoscaleControllerTest < DiagnosticsTestCase
  BILLING = Time.utc(2026, 10, 14, 21, 0)   # 23:00 in Stockholm, a Wednesday: inside the payments window
  QUIET = Time.utc(2026, 10, 17, 12, 0)     # a Saturday afternoon: no window

  # The in-memory stand-in for the files on the primary host, JSON round-tripped like them.
  class FakeStore
    attr_accessor :files, :decisions, :writes, :trimmed, :count

    def initialize
      @files = { "heartbeat" => {}, "state" => {}, "pauses" => {} }
      @decisions = []
      @writes = []
      @count = 0
    end

    def ensure_directory; end

    def heartbeat = files["heartbeat"]
    def state = files["state"]
    def pauses = files["pauses"]
    def decision_count = count

    def write_heartbeat(value) = write("heartbeat", value)
    def write_state(value) = write("state", value)

    def append_decisions(decisions)
      return if decisions.empty?

      @writes << "decisions"
      @decisions.concat(decisions.map { |decision| round_trip(decision.to_h) })
    end

    def trim_decisions(keep:)
      @trimmed = keep
    end

    private
      def write(file, value)
        @writes << file
        files[file] = round_trip(value)
      end

      def round_trip(value)
        JSON.parse(JSON.generate(Dash::Autoscale::Decision.json_safe(value)))
      end
  end

  # What Dash::Cli::Autoscale does for the controller, recorded.
  class FakeCli
    attr_reader :scale_sets, :replaced, :reports
    attr_accessor :on_scale_set, :on_replace

    def initialize(config_file)
      @config_file = config_file
      @scale_sets, @replaced, @reports = [], [], []
    end

    def reconfigure!
      DASH.reconfigure(config_file: @config_file)
    end

    def invoke_scale_set(role, count)
      @scale_sets << [ role.name, count ]
      on_scale_set&.call(role, count)
    end

    def replace_member(role, member, count:)
      @replaced << [ role.name, member.host, count ]
      on_replace&.call(role, member)
    end

    def report(message, _color = nil)
      @reports << message
    end
  end

  setup do
    configure :deploy_with_scale_schedule
    @store = FakeStore.new
    Dash::Autoscale::StateStore.stubs(:new).returns(@store)
    @cli = FakeCli.new(Pathname.new(File.expand_path("../fixtures/deploy_with_scale_schedule.yml", __dir__)))
    @members = [ member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "stopped") ]
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == "payments" }.returns(@members)
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == "reports" }.returns([])
    observe "payments", current: 3
    observe "reports", current: 1
  end

  test "a window starting scales out once, straight to its floor" do
    controller = start

    tick(controller, BILLING)
    assert_equal [ [ "payments", 6 ] ], @cli.scale_sets

    observe "payments", current: 6
    tick(controller, BILLING + 10)
    assert_equal [ [ "payments", 6 ] ], @cli.scale_sets, "at the floor it holds"
    assert_equal BILLING.iso8601, @store.state.dig("roles", "payments", "last_scale_out_at")
  end

  test "a steady role adds nothing to the decision log, and the heartbeat is written every tick" do
    observe "payments", current: 1
    controller = start
    tick(controller, QUIET)
    @store.writes.clear

    tick(controller, QUIET + 10)
    tick(controller, QUIET + 20)

    assert_equal [ "heartbeat", "heartbeat" ], @store.writes
    assert_equal (QUIET + 20).iso8601, @store.heartbeat["last_tick_at"]
  end

  test "logs the decisions that change, with every input" do
    observe "payments", current: 1
    controller = start
    tick(controller, BILLING - 86_400 * 7)
    tick(controller, BILLING)

    assert_equal [ [ "payments", "hold", [ "at_target" ] ], [ "reports", "hold", [ "at_target" ] ], [ "payments", "scale_out", [ "schedule_floor" ] ] ],
      @store.decisions.map { |decision| decision.values_at("role", "action", "reasons") }
    assert_equal 6, @store.decisions.last.dig("inputs", "floor")
  end

  test "after the window it steps down once per cooldown" do
    @store.files["state"] = { "roles" => { "payments" => { "last_scale_out_at" => BILLING.iso8601 } } }
    observe "payments", current: 6
    controller = start

    tick(controller, QUIET)
    assert_equal [ [ "payments", 3 ] ], @cli.scale_sets

    observe "payments", current: 3
    decisions = tick(controller, QUIET + 300)
    assert_equal [ "cooldown" ], decisions.first.reasons
    assert_equal 1, @cli.scale_sets.size

    tick(controller, QUIET + 600)
    assert_equal [ [ "payments", 3 ], [ "payments", 1 ] ], @cli.scale_sets
  end

  test "the heartbeat keeps beating while a scale action runs" do
    controller = start
    controller.stubs(:interval).returns(0.01)
    @cli.on_scale_set = ->(_role, _count) { sleep 0.2 }
    @store.writes.clear

    tick(controller, BILLING)

    assert_operator @store.writes.count("heartbeat"), :>=, 3, @store.writes.inspect
  end

  test "a beat that finds another controller's heartbeat does not overwrite it" do
    controller = start
    @store.files["heartbeat"] = { "controller_id" => "other" }

    assert_not controller.send(:beat_heartbeat)
    assert_equal({ "controller_id" => "other" }, @store.heartbeat)
  end

  test "a controller that lost the lease while it acted persists nothing" do
    controller = start
    @cli.on_scale_set = ->(_role, _count) { @store.files["heartbeat"] = { "controller_id" => "other" } }
    @store.writes.clear

    assert_raises(Dash::Autoscale::LeaseLost) { tick(controller, BILLING) }
    assert_empty @store.writes
  end

  test "a scale-out whose joined members cannot be read is still a scale-out" do
    controller = start
    @cli.on_scale_set = ->(_role, _count) { Dash::Autoscale::Pool.any_instance.stubs(:refresh!).raises(Dash::Autoscale::ProviderError, "down") }

    decision = tick(controller, BILLING).first

    assert_equal "scale_out", decision.action
    assert_equal BILLING.iso8601, @store.state.dig("roles", "payments", "last_scale_out_at")
    assert @cli.reports.any? { |line| line.include?("could not be read for their warmup") }
  end

  test "a member the scale-out powered on warms up and holds the next scale-in" do
    @cli.on_scale_set = ->(_role, _count) { @members << member("m3", "10.0.0.24", "started") }
    controller = start

    tick(controller, BILLING)

    assert_equal [ "10.0.0.24" ], @store.state.dig("roles", "payments", "joined").keys
  end

  test "a paused role is left alone" do
    @store.files["pauses"] = { "payments" => { "until" => "indefinite", "by" => "Jane" } }

    decisions = tick(start, BILLING)

    assert_equal [ "paused" ], decisions.first.reasons
    assert_empty @cli.scale_sets
  end

  test "a deploy lock it cannot get holds the role with lock_busy, and the next tick tries again" do
    @cli.on_scale_set = ->(_role, _count) { raise Dash::Cli::LockError, "Timed out waiting for deploy lock" }
    controller = start

    decision = tick(controller, BILLING).first
    assert_equal "hold", decision.action
    assert_equal [ "lock_busy" ], decision.reasons
    assert_equal "Timed out waiting for deploy lock", decision.error
    assert_equal({ action: "scale_out", to: 6 }, decision.inputs[:attempted])
    assert_nil @store.state.dig("roles", "payments", "last_scale_out_at")

    tick(controller, BILLING + 10)
    assert_equal 2, @cli.scale_sets.size
  end

  test "one role failing does not stop the other" do
    Dash::Autoscale::Observation.stubs(:take).with { |role| role.name == "payments" }.raises(RuntimeError, "boom")
    observe "reports", current: 1

    decisions = tick(start, Time.utc(2026, 10, 15, 7, 30)) # 09:30 on a Thursday in Stockholm

    assert_equal [ "action_failed" ], decisions.first.reasons
    assert_equal "RuntimeError: boom", decisions.first.error
    assert_equal [ [ "reports", 4 ] ], @cli.scale_sets
  end

  test "a failing scale set is action_failed, with its message" do
    @cli.on_scale_set = ->(_role, _count) { raise Dash::Cli::BootError, "unhealthy" }

    decision = tick(start, BILLING).first

    assert_equal [ "action_failed" ], decision.reasons
    assert_equal "Dash::Cli::BootError: unhealthy", decision.error
  end

  test "an unreachable member is replaced after boot_timeout, not before" do
    observe "payments", current: 3, unreachable: { "10.0.0.22" => "ECONNREFUSED" }
    controller = start

    tick(controller, BILLING)
    assert_empty @cli.replaced
    assert_empty @cli.scale_sets, "a role with an unreachable member does not scale"

    tick(controller, BILLING + 240)
    assert_equal [ [ "payments", "10.0.0.22", 3 ] ], @cli.replaced
    assert_equal({}, @store.state.dig("roles", "payments", "unreachable"))
  end

  test "an unreachable host is skipped by the lock's run directory sweep while the tick acts" do
    Dash::Autoscale::Observation.stubs(:take).with { |role| role.name == "reports" }
      .returns(Dash::Autoscale::Observation.new(role: DASH.config.role(:reports), current: 1, unreadable_baseline: { "1.1.1.3" => "down" }))
    seen = nil
    @cli.on_scale_set = ->(_role, _count) { seen = DASH.run_directory_ensured_on.dup }

    tick(start, BILLING)

    assert_equal [ "1.1.1.3" ], seen
    assert_empty DASH.run_directory_ensured_on
  end

  test "an unreachable baseline host holds the role" do
    Dash::Autoscale::Observation.stubs(:take).with { |role| role.name == "payments" }
      .returns(Dash::Autoscale::Observation.new(role: DASH.config.role(:payments), current: 0, unreadable_baseline: { "1.1.1.2" => "down" }))

    decision = tick(start, BILLING).first

    assert_equal [ "host_unreachable" ], decision.reasons
    assert_empty @cli.scale_sets
    assert_empty @cli.replaced
  end

  test "refuses to start while another controller's heartbeat is alive" do
    @store.files["heartbeat"] = { "controller_id" => "other", "hostname" => "ops-2", "pid" => 7, "interval" => 10, "last_tick_at" => (BILLING - 5).iso8601 }

    error = assert_raises(Dash::Autoscale::LeaseHeld) { start(now: BILLING) }
    assert_match "controller other on ops-2 (pid 7", error.message
    assert_match "--takeover", error.message
  end

  test "starts over a stale or stopped heartbeat, and over a live one with --takeover" do
    @store.files["heartbeat"] = { "controller_id" => "other", "interval" => 10, "last_tick_at" => (BILLING - 31).iso8601 }
    assert_equal start(now: BILLING).id, @store.heartbeat["controller_id"]

    @store.files["heartbeat"] = { "controller_id" => "other", "interval" => 10, "last_tick_at" => (BILLING - 1).iso8601, "stopped_at" => BILLING.iso8601 }
    assert_equal start(now: BILLING).id, @store.heartbeat["controller_id"]

    @store.files["heartbeat"] = { "controller_id" => "other", "interval" => 10, "last_tick_at" => (BILLING - 1).iso8601 }
    assert_equal start(now: BILLING, takeover: true).id, @store.heartbeat["controller_id"]
  end

  test "stops when another controller took the lease" do
    controller = start
    @store.files["heartbeat"] = @store.heartbeat.merge("controller_id" => "other")

    assert_raises(Dash::Autoscale::LeaseLost) { tick(controller, BILLING) }
    assert_empty @cli.scale_sets
  end

  test "a dry run decides and prints, and neither acts nor writes" do
    controller = start(dry_run: true)

    decisions = tick(controller, BILLING)

    assert_equal "scale_out", decisions.first.action
    assert_empty @cli.scale_sets
    assert_empty @store.writes
    assert_includes @cli.reports, "payments: scale_out 3 -> 6 (schedule_floor: window \"0 22 14 * *\" min 6)"
  end

  test "refuses to start without a role it could control" do
    DASH.specific_roles = [ "web" ]
    @cli.define_singleton_method(:reconfigure!) { DASH.reconfigure(config_file: @config_file); DASH.specific_roles = [ "web" ] }

    error = assert_raises(ArgumentError) { start }
    assert_match "No scaled role in scope has a scale/schedule", error.message
  end

  test "the loop ticks until stopped, then marks its heartbeat stopped" do
    clock = BILLING
    controller = Dash::Autoscale::Controller.new(cli: @cli, clock: -> { clock }, sleeper: ->(seconds) { clock += seconds; @ticks_slept = @ticks_slept.to_i + 1 })
    controller.stubs(:tick).with { controller.stop! if (@ticks = @ticks.to_i + 1) == 2; true }.returns([])

    controller.run

    assert_equal 2, @ticks
    assert @store.heartbeat["stopped_at"]
  end

  test "a tick that fails as a whole is reported and the loop goes on" do
    clock = BILLING
    controller = Dash::Autoscale::Controller.new(cli: @cli, clock: -> { clock }, sleeper: ->(seconds) { clock += seconds })
    calls = 0
    controller.define_singleton_method(:tick) do
      calls += 1
      stop! if calls == 2
      raise Errno::ECONNREFUSED, "1.1.1.1" if calls == 1
      []
    end

    controller.run

    assert_equal 2, calls
    assert_includes @cli.reports, "Autoscale tick failed: Errno::ECONNREFUSED: Connection refused - 1.1.1.1"
  end

  test "a lost lease ends the loop without overwriting the other controller's heartbeat" do
    controller = Dash::Autoscale::Controller.new(cli: @cli, clock: -> { BILLING }, sleeper: ->(_) { })
    controller.define_singleton_method(:tick) do
      @store_ref.files["heartbeat"] = { "controller_id" => "other" }
      raise Dash::Autoscale::LeaseLost, "taken"
    end
    controller.instance_variable_set(:@store_ref, @store)

    assert_raises(Dash::Autoscale::LeaseLost) { controller.run }
    assert_equal({ "controller_id" => "other" }, @store.heartbeat)
  end

  test "records each tick's decisions and updates the metrics" do
    path = File.join(Dir.mktmpdir, "ticks.jsonl")
    controller = start(recorder: Dash::Autoscale::Recorder.new(path))

    tick(controller, BILLING)

    line = JSON.parse(File.readlines(path).last)
    assert_equal BILLING.iso8601, line["at"]
    assert_equal [ "payments", "reports" ], line["decisions"].map { |decision| decision["role"] }
    assert_match 'dash_autoscale_containers{role="payments",state="target"} 6', controller.metrics.render
    assert_match 'dash_autoscale_members{role="payments",state="started"} 1', controller.metrics.render
  end

  test "trims the decision log past its limit, checking at most once an hour" do
    @store.count = 10_001
    controller = start

    tick(controller, BILLING)
    assert_equal 10_000, @store.trimmed

    @store.trimmed = nil
    tick(controller, BILLING + 60)
    assert_nil @store.trimmed
  end

  private
    def start(now: BILLING, **options)
      Dash::Autoscale::Controller.new(cli: @cli, clock: -> { now }, **options).tap(&:start)
    end

    def tick(controller, now)
      controller.instance_variable_set(:@clock, -> { now })
      controller.tick
    end

    def observe(role_name, current:, unreachable: {})
      Dash::Autoscale::Observation.stubs(:take).with { |role| role.name == role_name }.returns(
        Dash::Autoscale::Observation.new(role: DASH.config.role(role_name), current: current, pool: @members.select { |m| role_name == "payments" && m }, unreachable_members: unreachable))
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: "payments", state: state)
    end
end
