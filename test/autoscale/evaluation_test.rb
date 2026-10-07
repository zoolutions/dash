require_relative "../diagnostics/diagnostics_test_case"

# payments: replicas 1-3 on 1 to 3 hosts, a window from 22:00 on the 14th (Stockholm) for
# 30h asking for 6, boot_timeout 240, warmup 300, cooldown down 600, step 3.
class AutoscaleEvaluationTest < DiagnosticsTestCase
  BILLING = Time.utc(2026, 10, 14, 21, 0)  # 23:00 in Stockholm, inside the window
  QUIET = Time.utc(2026, 10, 20, 12, 0)

  setup do
    configure :deploy_with_scale_schedule
  end

  test "asks the policy with what it observed and what the state remembers" do
    decision = evaluate(now: BILLING, observation: observation(current: 3))

    assert_equal "scale_out", decision.action
    assert_equal 6, decision.to
    assert_equal [ "schedule_floor" ], decision.reasons
  end

  test "evaluates the schedule in autoscale.timezone" do
    # 21:30 UTC on the 14th is 23:30 in Stockholm (inside), but 21:30 local time in UTC is not.
    assert_equal "scale_out", evaluate(now: Time.utc(2026, 10, 14, 21, 30), observation: observation(current: 3)).action
    assert_equal "hold", evaluate(now: Time.utc(2026, 10, 14, 19, 30), observation: observation(current: 1)).action
  end

  test "a member that stops answering starts its unreachable clock now and is replaced after boot_timeout" do
    state = Dash::Autoscale::RoleState.from(nil)

    first = evaluate(now: BILLING, state: state, observation: observation(current: 3, unreachable: { "10.0.0.22" => "ECONNREFUSED" }))
    assert_equal [ "member_unreachable" ], first.reasons
    assert_equal({ "10.0.0.22" => BILLING }, state.unreachable)

    later = evaluate(now: BILLING + 240, state: state, observation: observation(current: 3, unreachable: { "10.0.0.22" => "ECONNREFUSED" }))
    assert_equal "replace_member", later.action
    assert_equal "10.0.0.22", later.member_host
  end

  test "a member that answers again is forgotten" do
    state = Dash::Autoscale::RoleState.from("unreachable" => { "10.0.0.22" => "2026-10-14T20:00:00Z" })

    evaluate(now: BILLING, state: state, observation: observation(current: 6))

    assert_equal({}, state.unreachable)
  end

  test "a pool error keeps what the state remembers about members" do
    state = Dash::Autoscale::RoleState.from("unreachable" => { "10.0.0.22" => "2026-10-14T20:00:00Z" }, "joined" => { "10.0.0.22" => "2026-10-14T20:00:00Z" })

    decision = evaluate(now: BILLING, state: state, observation: Dash::Autoscale::Observation.new(role: payments, pool_error: "down"))

    assert_equal [ "pool_unreadable" ], decision.reasons
    assert_equal [ "10.0.0.22" ], state.unreachable.keys
    assert_equal [ "10.0.0.22" ], state.joined.keys
  end

  test "a member the controller joined warms up and holds a scale-in" do
    state = Dash::Autoscale::RoleState.from("joined" => { "10.0.0.22" => (QUIET - 60).iso8601 })

    decision = evaluate(now: QUIET, state: state, observation: observation(current: 6))

    assert_equal [ "warming_up" ], decision.reasons
  end

  test "a pause holds the role" do
    pause = Dash::Autoscale::Pause.new(ends_at: :indefinite)

    assert_equal [ "paused" ], evaluate(now: BILLING, pause: pause, observation: observation(current: 3)).reasons
  end

  private
    def payments
      DASH.config.role(:payments)
    end

    def evaluate(now:, observation:, state: Dash::Autoscale::RoleState.from(nil), pause: nil)
      Dash::Autoscale::Evaluation.new(role: payments, now: now, state: state, pause: pause, observation: observation).decide
    end

    def observation(current:, unreachable: {})
      member = Dash::Autoscale::Member.new(id: "m1", host: "10.0.0.22", role: "payments", state: "started")
      Dash::Autoscale::Observation.new(role: payments, current: current, pool: [ member ], unreachable_members: unreachable)
    end
end
