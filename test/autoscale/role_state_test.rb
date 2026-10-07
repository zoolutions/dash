require "test_helper"

class AutoscaleRoleStateTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 14, 22, 0)

  test "an empty state has no history" do
    state = Dash::Autoscale::RoleState.from(nil)

    assert_equal({ last_scale_out_at: nil, last_scale_in_at: nil }, state.history)
    assert_equal({}, state.unreachable)
    assert_equal({}, state.joined)
    assert_nil state.last_decision
  end

  test "reads what state.json holds, times as Time" do
    state = Dash::Autoscale::RoleState.from(
      "last_scale_out_at" => "2026-10-14T22:00:00Z", "last_scale_in_at" => "2026-10-14T20:00:00Z",
      "unreachable" => { "10.0.0.22" => "2026-10-14T21:58:00Z" }, "joined" => { "10.0.0.23" => "2026-10-14T21:00:00Z" },
      "last_decision" => { "action" => "hold", "reasons" => [ "at_target" ] })

    assert_equal({ last_scale_out_at: NOW, last_scale_in_at: Time.utc(2026, 10, 14, 20) }, state.history)
    assert_equal({ "10.0.0.22" => Time.utc(2026, 10, 14, 21, 58) }, state.unreachable)
    assert_equal({ "10.0.0.23" => Time.utc(2026, 10, 14, 21) }, state.joined)
    assert_equal({ "action" => "hold", "reasons" => [ "at_target" ] }, state.last_decision)
  end

  test "a time that does not parse is dropped, not raised" do
    state = Dash::Autoscale::RoleState.from("last_scale_out_at" => "yesterday", "unreachable" => { "10.0.0.22" => 12 })

    assert_nil state.history[:last_scale_out_at]
    assert_equal({}, state.unreachable)
  end

  test "an unreachable host keeps the time it was first seen unreachable; one that answers again is forgotten" do
    state = Dash::Autoscale::RoleState.from("unreachable" => { "10.0.0.22" => "2026-10-14T21:58:00Z", "10.0.0.23" => "2026-10-14T21:59:00Z" })

    state.observe_unreachable([ "10.0.0.22", "10.0.0.24" ], now: NOW)

    assert_equal({ "10.0.0.22" => Time.utc(2026, 10, 14, 21, 58), "10.0.0.24" => NOW }, state.unreachable)
  end

  test "joins are kept for the members still started" do
    state = Dash::Autoscale::RoleState.from("joined" => { "10.0.0.22" => "2026-10-14T21:58:00Z", "10.0.0.23" => "2026-10-14T21:59:00Z" })

    state.joined_at([ "10.0.0.24" ], now: NOW)
    state.keep_members([ "10.0.0.22", "10.0.0.24" ])

    assert_equal({ "10.0.0.22" => Time.utc(2026, 10, 14, 21, 58), "10.0.0.24" => NOW }, state.joined)
  end

  test "records the scale actions it took" do
    state = Dash::Autoscale::RoleState.from(nil)

    state.scaled("scale_out", now: NOW)
    state.scaled("scale_in", now: NOW + 600)

    assert_equal({ last_scale_out_at: NOW, last_scale_in_at: NOW + 600 }, state.history)
  end

  test "a decision is logged when its action or reasons change, and every action is" do
    state = Dash::Autoscale::RoleState.from(nil)
    hold = Dash::Autoscale::Decision.new(role: "payments", action: "hold", from: 3, to: 3, reasons: [ "at_target" ], at: NOW)
    out = Dash::Autoscale::Decision.new(role: "payments", action: "scale_out", from: 3, to: 10, reasons: [ "schedule_floor" ], at: NOW)

    assert state.log?(hold)
    state.logged(hold)
    assert_not state.log?(hold)
    assert state.log?(Dash::Autoscale::Decision.new(role: "payments", action: "hold", from: 3, to: 3, reasons: [ "cooldown" ], at: NOW)),
      "a hold whose reasons changed is logged"
    assert state.log?(out)
    state.logged(out)
    assert state.log?(out), "every action is logged, even a repeated one"
  end

  test "forgets a replaced member" do
    state = Dash::Autoscale::RoleState.from("unreachable" => { "10.0.0.22" => "2026-10-14T21:58:00Z" }, "joined" => { "10.0.0.22" => "2026-10-14T21:00:00Z" })

    state.forget("10.0.0.22")

    assert_equal({}, state.unreachable)
    assert_equal({}, state.joined)
  end

  test "writes back what it read, as JSON-safe values" do
    json = { "last_scale_out_at" => "2026-10-14T22:00:00Z", "last_scale_in_at" => nil, "unreachable" => { "10.0.0.22" => "2026-10-14T21:58:00Z" },
      "joined" => {}, "last_decision" => { "action" => "hold", "reasons" => [ "at_target" ] } }

    assert_equal json, Dash::Autoscale::RoleState.from(json).to_h
  end
end
