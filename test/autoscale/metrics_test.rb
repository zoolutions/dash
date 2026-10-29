require "test_helper"

class AutoscaleMetricsTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 14, 22, 0)

  test "renders the Prometheus text format" do
    metrics = Dash::Autoscale::Metrics.new
    metrics.record_tick(decisions: [ decision("payments", "scale_out", 3, 6, [ "schedule_floor" ]), decision("reports", "hold", 2, 2, [ "at_target" ]) ],
      members: { "payments" => %w[ started started stopped ], "reports" => [] }, at: NOW, duration: 1.25)
    metrics.record_tick(decisions: [ decision("payments", "hold", 6, 6, [ "at_target" ]) ], members: { "payments" => %w[ started ] }, at: NOW + 10, duration: 0.5)

    assert_equal <<~TEXT, metrics.render
      # HELP dash_autoscale_containers Containers of a scaled role: running, and the target the controller holds it to.
      # TYPE dash_autoscale_containers gauge
      dash_autoscale_containers{role="payments",state="running"} 6
      dash_autoscale_containers{role="payments",state="target"} 6
      dash_autoscale_containers{role="reports",state="running"} 2
      dash_autoscale_containers{role="reports",state="target"} 2
      # HELP dash_autoscale_decisions_total Decisions the controller took, per role, action and reason.
      # TYPE dash_autoscale_decisions_total counter
      dash_autoscale_decisions_total{role="payments",action="hold",reason="at_target"} 1
      dash_autoscale_decisions_total{role="payments",action="scale_out",reason="schedule_floor"} 1
      dash_autoscale_decisions_total{role="reports",action="hold",reason="at_target"} 1
      # HELP dash_autoscale_members Pool members of a scaled role, per provider state.
      # TYPE dash_autoscale_members gauge
      dash_autoscale_members{role="payments",state="started"} 1
      # HELP dash_autoscale_signal The last sample of a scaled role's signal; absent while it cannot be read.
      # TYPE dash_autoscale_signal gauge
      # HELP dash_autoscale_guard The last sample of each of a scaled role's guards, by its index in hold_when.
      # TYPE dash_autoscale_guard gauge
      # HELP dash_autoscale_last_tick_timestamp_seconds When the last tick finished, in Unix seconds.
      # TYPE dash_autoscale_last_tick_timestamp_seconds gauge
      dash_autoscale_last_tick_timestamp_seconds #{(NOW + 10).to_i}
      # HELP dash_autoscale_tick_duration_seconds How long the last tick took.
      # TYPE dash_autoscale_tick_duration_seconds gauge
      dash_autoscale_tick_duration_seconds 0.5
    TEXT
  end

  test "a signal and its guards, as of the last tick; a sample that could not be read is absent" do
    metrics = Dash::Autoscale::Metrics.new
    inputs = { signal: { source: "sidekiq", value: 12.5 }, guards: [ { index: 0, source: "postgres", value: 195.0 }, { index: 1, source: "prometheus", value: nil } ] }
    metrics.record_tick(decisions: [ decision("payments", "hold", 2, 2, [ "held_by_guard" ], inputs) ], members: {}, at: NOW, duration: 0.1)

    assert_match %(dash_autoscale_signal{role="payments",source="sidekiq"} 12.5\n), metrics.render
    assert_match %(dash_autoscale_guard{role="payments",guard="0",source="postgres"} 195.0\n), metrics.render
    assert_no_match(/guard="1"/, metrics.render)

    metrics.record_tick(decisions: [ decision("payments", "hold", 2, 2, [ "missing_data" ], inputs.merge(signal: { source: "sidekiq", value: nil })) ], members: {}, at: NOW, duration: 0.1)
    assert_no_match(/dash_autoscale_signal\{/, metrics.render)
  end

  test "a role whose count is unknown has no running gauge" do
    metrics = Dash::Autoscale::Metrics.new
    metrics.record_tick(decisions: [ decision("payments", "hold", nil, nil, [ "pool_unreadable" ]) ], members: {}, at: NOW, duration: 0.1)

    assert_no_match(/dash_autoscale_containers\{/, metrics.render)
    assert_match 'dash_autoscale_decisions_total{role="payments",action="hold",reason="pool_unreadable"} 1', metrics.render
  end

  test "escapes label values" do
    metrics = Dash::Autoscale::Metrics.new
    metrics.record_tick(decisions: [ decision(%(a"b\\c), "hold", 1, 1, [ "at_target" ]) ], members: {}, at: NOW, duration: 0.1)

    assert_match 'role="a\"b\\\\c"', metrics.render
  end

  test "before the first tick there are only the headers" do
    assert_no_match(/^dash_autoscale_last_tick_timestamp_seconds /, Dash::Autoscale::Metrics.new.render)
  end

  private
    def decision(role, action, from, to, reasons, inputs = {})
      Dash::Autoscale::Decision.new(role: role, action: action, from: from, to: to, reasons: reasons, inputs: { floor: to }.merge(inputs), at: NOW)
    end
end
