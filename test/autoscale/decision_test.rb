require "test_helper"

class AutoscaleDecisionTest < ActiveSupport::TestCase
  test "an error handed in as an exception is its message in JSON" do
    assert_equal({ "1.1.1.2" => "down" }, Dash::Autoscale::Decision.json_safe("1.1.1.2" => RuntimeError.new("down")))
  end

  AT = Time.utc(2026, 10, 14, 22, 0, 5)

  test "to_h is JSON-safe: ISO 8601 times in UTC, strings for symbols, all the way down" do
    zone = ActiveSupport::TimeZone["Europe/Stockholm"]
    decision = Dash::Autoscale::Decision.new(role: "payments", action: "hold", from: 4, to: 4, reasons: [ "paused" ],
      inputs: { paused_until: :indefinite, windows: [ { started_at: zone.parse("2026-10-15 00:00") } ] }, at: AT)

    assert_equal({ role: "payments", action: "hold", from: 4, to: 4, reasons: [ "paused" ],
      inputs: { paused_until: "indefinite", windows: [ { started_at: "2026-10-14T22:00:00Z" } ] },
      eligible_at: nil, at: "2026-10-14T22:00:05Z", error: nil }, decision.to_h)
    assert_equal decision.to_h, JSON.parse(JSON.generate(decision.to_h), symbolize_names: true)
  end

  test "a scale summary names the window that set the floor" do
    decision = decision(action: "scale_out", from: 4, to: 10, reasons: [ "schedule_floor" ],
      inputs: { windows: [ { cron: "0 9 * * 1-5", min: 4 }, { cron: "0 22 1,15 * *", min: 10 } ] })

    assert_equal 'payments: scale_out 4 -> 10 (schedule_floor: window "0 22 1,15 * *" min 10)', decision.summary
  end

  test "a hold summary gives the count and when it may act" do
    assert_equal "payments: hold at 7 (cooldown until 2026-10-14T22:10:05Z)",
      decision(action: "hold", from: 7, to: 7, reasons: [ "cooldown" ], eligible_at: AT + 600).summary
    assert_equal "payments: hold at 1 (at_target)", decision(action: "hold", from: 1, to: 1, reasons: [ "at_target" ]).summary
    assert_equal "payments: hold at ? (pool_unreadable: UpCloud answered 503)",
      decision(action: "hold", from: nil, reasons: [ "pool_unreadable" ], error: "UpCloud answered 503").summary
  end

  test "a replace summary names the member" do
    decision = decision(action: "replace_member", from: 6, to: 6, reasons: [ "member_unreachable" ], inputs: { replace: "10.0.0.22" })

    assert_equal "10.0.0.22", decision.member_host
    assert_equal "payments: replace_member 10.0.0.22 (member_unreachable)", decision.summary
  end

  test "the codes" do
    assert_equal %w[ scale_out scale_in replace_member hold ], Dash::Autoscale::Decision::ACTIONS
    assert_includes Dash::Autoscale::Decision::REASONS, "lock_busy"
    assert_equal 12, Dash::Autoscale::Decision::REASONS.size
  end

  private
    def decision(**attributes)
      Dash::Autoscale::Decision.new(role: "payments", at: AT, **attributes)
    end
end
