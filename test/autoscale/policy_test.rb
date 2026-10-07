require "test_helper"

# payments: 1 baseline host, replicas 1-3, scale 1-4 hosts - so 1 to 12 containers; a window
# from 22:00 on the 14th for 30h asks for 10, one at 09:00 on weekdays for 1h asks for 4.
class AutoscalePolicyTest < ActiveSupport::TestCase
  QUIET = Time.utc(2026, 10, 6, 12, 0)          # a Tuesday, outside both windows
  BILLING = Time.utc(2026, 10, 14, 23, 0)        # inside the 30h window
  MORNING = Time.utc(2026, 10, 15, 9, 30)        # inside both: 10 wins

  setup do
    @scale = { "min" => 1, "max" => 4, "step" => 3, "warmup" => 300, "boot_timeout" => 240, "cooldown" => { "down" => 600 },
      "schedule" => [ { "cron" => "0 22 14 * *", "for" => "30h", "min" => 10 }, { "cron" => "0 9 * * 1-5", "for" => "1h", "min" => 4 } ] }
  end

  test "below the floor a window sets, it scales out straight to it" do
    decision = decide(now: BILLING, current: 1)

    assert_equal "scale_out", decision.action
    assert_equal 1, decision.from
    assert_equal 10, decision.to
    assert_equal [ "schedule_floor" ], decision.reasons
    assert_equal BILLING, decision.at
    assert_equal "payments", decision.role
  end

  test "overlapping windows take the largest min" do
    decision = decide(now: MORNING, current: 1)

    assert_equal 10, decision.to
    assert_equal [ "0 22 14 * *", "0 9 * * 1-5" ], decision.inputs[:windows].map { |window| window[:cron] }
  end

  test "below min with no window active it scales out to min" do
    @scale["min"] = 2

    decision = decide(now: QUIET, current: 1)
    assert_equal [ "scale_out", 2, [ "at_min" ] ], [ decision.action, decision.to, decision.reasons ]
  end

  test "at the floor it holds" do
    assert_equal [ "hold", 10, 10, [ "at_target" ] ], decision_tuple(decide(now: BILLING, current: 10))
    assert_equal [ "hold", 1, 1, [ "at_target" ] ], decision_tuple(decide(now: QUIET, current: 1))
  end

  test "a floor above max is clamped to it" do
    role = role_with(replicas: { "min" => 1, "max" => 3 }, scale: @scale.merge("max" => 4))
    role.scale.schedule.first.stubs(:min).returns(20)

    decision = policy(role: role, now: BILLING, current: 1).decide
    assert_equal [ "scale_out", 12, [ "schedule_floor", "at_max" ] ], [ decision.action, decision.to, decision.reasons ]
  end

  test "scale-out ignores warmup and cooldown" do
    decision = decide(now: BILLING, current: 4, warming: { "10.0.0.22" => BILLING - 10 }, history: { last_scale_out_at: BILLING - 5 })

    assert_equal [ "scale_out", 4, 10 ], decision_tuple(decision).first(3)
  end

  test "after a window ends it scales in a step at a time, one step per cooldown" do
    ended = Time.utc(2026, 10, 16, 4, 0)
    history = { last_scale_out_at: BILLING }
    current = 10
    steps = []

    6.times do |tick|
      now = ended + (tick * 600)
      decision = decide(now: now, current: current, history: history)
      steps << [ decision.action, decision.to ]

      if decision.action == "scale_in"
        current = decision.to
        history = history.merge(last_scale_in_at: now)
      end
    end

    assert_equal [ [ "scale_in", 7 ], [ "scale_in", 4 ], [ "scale_in", 1 ], [ "hold", 1 ], [ "hold", 1 ], [ "hold", 1 ] ], steps
  end

  test "scale-in waits cooldown.down after the last action of either kind" do
    now = QUIET
    decision = decide(now: now, current: 7, history: { last_scale_out_at: now - 100 })

    assert_equal [ "hold", 7, 7, [ "cooldown" ] ], decision_tuple(decision)
    assert_equal now + 500, decision.eligible_at

    decision = decide(now: now, current: 7, history: { last_scale_out_at: now - 3000, last_scale_in_at: now - 60 })
    assert_equal now + 540, decision.eligible_at

    assert_equal "scale_in", decide(now: now, current: 7, history: { last_scale_in_at: now - 600 }).action
  end

  test "scale-in never runs while a member warms up" do
    now = QUIET
    decision = decide(now: now, current: 7, warming: { "10.0.0.22" => now - 100, "10.0.0.23" => now - 1000 })

    assert_equal [ "hold", 7, 7, [ "warming_up" ] ], decision_tuple(decision)
    assert_equal now + 200, decision.eligible_at
    assert_equal [ "10.0.0.22" ], decision.inputs[:warming]

    assert_equal "scale_in", decide(now: now, current: 7, warming: { "10.0.0.22" => now - 300 }).action
  end

  test "a manual count above the target is scaled back after the cooldown" do
    assert_equal [ "scale_in", 9, 6 ], decision_tuple(decide(now: QUIET, current: 9)).first(3)
  end

  test "a scale-in never goes below the floor" do
    assert_equal [ "scale_in", 11, 10 ], decision_tuple(decide(now: BILLING, current: 11)).first(3)
  end

  test "a scale-in step lands on a count the hosts can split" do
    role = role_with(replicas: 3, scale: @scale.merge("step" => 2, "schedule" => []))

    # 9 containers on 3 hosts of exactly 3: 7 cannot be placed, so the step goes to 6.
    decision = policy(role: role, now: QUIET, current: 9).decide
    assert_equal [ "scale_in", 9, 6 ], decision_tuple(decision).first(3)
  end

  test "paused holds whatever the count, until the pause expires" do
    decision = decide(now: BILLING, current: 1, paused_until: BILLING + 60)
    assert_equal [ "hold", 1, 1, [ "paused" ] ], decision_tuple(decision)
    assert_equal BILLING + 60, decision.eligible_at

    assert_equal [ "paused" ], decide(now: BILLING, current: 1, paused_until: :indefinite).reasons
    assert_nil decide(now: BILLING, current: 1, paused_until: :indefinite).eligible_at
    assert_equal "scale_out", decide(now: BILLING, current: 1, paused_until: BILLING).action
  end

  test "a pool that cannot be read holds, with the error" do
    decision = decide(now: BILLING, current: 1, pool_error: "UpCloud answered 503")

    assert_equal [ "hold", [ "pool_unreadable" ] ], [ decision.action, decision.reasons ]
    assert_equal "UpCloud answered 503", decision.error
  end

  test "errors handed in as exceptions are recorded as their messages" do
    decision = decide(now: BILLING, current: 1, pool_error: Dash::Autoscale::ProviderError.new("UpCloud answered 503"))
    assert_equal "UpCloud answered 503", decision.error
    assert_equal "UpCloud answered 503", JSON.parse(JSON.generate(decision.to_h))["error"]

    decision = decide(now: BILLING, current: 0, unreadable_baseline: { "1.1.1.3" => Errno::ECONNREFUSED.new })
    assert_equal "1.1.1.3: Connection refused", decision.error
  end

  test "an unreachable baseline host holds: its count is unknown, and dash never powers it off" do
    decision = decide(now: BILLING, current: 0, unreadable_baseline: { "1.1.1.3" => "Errno::ECONNREFUSED" })

    assert_equal [ "hold", [ "host_unreachable" ] ], [ decision.action, decision.reasons ]
    assert_equal "1.1.1.3: Errno::ECONNREFUSED", decision.error
  end

  test "an unreachable member holds until boot_timeout, then is replaced" do
    now = BILLING
    decision = decide(now: now, current: 3, unreachable: { "10.0.0.22" => now - 100 })

    assert_equal [ "hold", [ "member_unreachable" ] ], [ decision.action, decision.reasons ]
    assert_equal now + 140, decision.eligible_at

    decision = decide(now: now, current: 3, unreachable: { "10.0.0.22" => now - 240 })
    assert_equal [ "replace_member", 3, 3, [ "member_unreachable" ] ], decision_tuple(decision)
    assert_equal "10.0.0.22", decision.member_host
  end

  test "a member still warming up is not replaced before its warmup ends" do
    now = BILLING
    decision = decide(now: now, current: 3, unreachable: { "10.0.0.22" => now - 250 }, warming: { "10.0.0.22" => now - 280 })

    assert_equal [ "hold", [ "member_unreachable" ] ], [ decision.action, decision.reasons ]
    assert_equal now + 20, decision.eligible_at
  end

  test "one member replaced per tick, the longest unreachable first" do
    now = BILLING
    decision = decide(now: now, current: 3, unreachable: { "10.0.0.22" => now - 300, "10.0.0.23" => now - 900 })

    assert_equal "10.0.0.23", decision.member_host
  end

  test "pause beats an unreachable member" do
    decision = decide(now: BILLING, current: 3, unreachable: { "10.0.0.22" => BILLING - 900 }, paused_until: :indefinite)

    assert_equal [ "paused" ], decision.reasons
  end

  test "inputs carry every value the decision used" do
    inputs = decide(now: BILLING, current: 4, history: { last_scale_out_at: BILLING - 30 }).inputs

    assert_equal 4, inputs[:current]
    assert_equal 10, inputs[:floor]
    assert_equal 1, inputs[:min_count]
    assert_equal 12, inputs[:max_count]
    assert_equal 3, inputs[:step]
    assert_equal 60, inputs[:cooldown_up]
    assert_equal 600, inputs[:cooldown_down]
    assert_equal 300, inputs[:warmup]
    assert_equal BILLING - 30, inputs[:last_scale_out_at]
    assert_equal [ { cron: "0 22 14 * *", for: 108_000, min: 10, started_at: Time.utc(2026, 10, 14, 22), ends_at: Time.utc(2026, 10, 16, 4) } ], inputs[:windows]
  end

  test "windows are evaluated in the time zone" do
    stockholm = ActiveSupport::TimeZone["Europe/Stockholm"]

    # 21:30 UTC on the 14th is 23:30 in Stockholm: inside the window there, not in UTC.
    assert_equal "scale_out", decide(now: Time.utc(2026, 10, 14, 21, 30), current: 1, time_zone: stockholm).action
    assert_equal "hold", decide(now: Time.utc(2026, 10, 14, 21, 30), current: 1).action
  end

  private
    def decide(**inputs)
      policy(**inputs).decide
    end

    def policy(role: role_with, now:, current:, time_zone: ActiveSupport::TimeZone["UTC"], **inputs)
      Dash::Autoscale::Policy.new(role: role, now: now, time_zone: time_zone, current: current, **inputs)
    end

    def decision_tuple(decision)
      [ decision.action, decision.from, decision.to, decision.reasons ]
    end

    def role_with(replicas: { "min" => 1, "max" => 3 }, scale: @scale)
      Dash::Configuration.new({
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: {
          "web" => [ "1.1.1.1" ],
          "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "bundle exec sidekiq", "healthcheck" => false, "replicas" => replicas, "scale" => scale }
        },
        autoscale: { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } } }
      }).role(:payments)
    end
end
