require "test_helper"

# payments: replicas 1-2 on 1 to 4 hosts (1 to 8 containers), a Sidekiq signal held between
# 2 and 10 seconds (up after 30s, down after 600s), step 2, cooldown up 60 / down 600,
# warmup 300, a Postgres guard above 180, and a window from 22:00 on the 14th asking for 6.
class AutoscalePolicySignalTest < ActiveSupport::TestCase
  QUIET = Time.utc(2026, 10, 6, 12, 0)
  BILLING = Time.utc(2026, 10, 14, 23, 0)

  setup do
    @scale = { "min" => 1, "max" => 4, "step" => 2, "warmup" => 300, "cooldown" => { "up" => 60, "down" => 600 },
      "schedule" => [ { "cron" => "0 22 14 * *", "for" => "30h", "min" => 6 } ],
      "signal" => { "source" => "sidekiq", "queues" => [ "default" ] },
      "up" => { "above" => 10, "for" => 30 }, "down" => { "below" => 2, "for" => 600 },
      "hold_when" => [ { "source" => "postgres", "query" => "SELECT count(*) FROM pg_stat_activity", "above" => 180 } ] }
  end

  test "sustained above the band for up.for, it scales out by a step" do
    decision = decide(current: 2, value: 12.4, above_since: QUIET - 45)

    assert_equal [ "scale_out", 2, 4, [ "above_threshold" ] ], tuple(decision)
    assert_equal "payments: scale_out 2 -> 4 (above_threshold: 12.4 > 10 for 45s)", decision.summary
  end

  test "above, but not yet for up.for, it holds until it has been" do
    decision = decide(current: 2, value: 12.4, above_since: QUIET - 10)

    assert_equal [ "hold", 2, 2, [ "above_threshold" ] ], tuple(decision)
    assert_equal QUIET + 20, decision.eligible_at
    assert_match "above_threshold: 12.4 > 10 until #{(QUIET + 20).iso8601}", decision.summary
  end

  test "up.for 0 scales out on the first sample above" do
    @scale["up"] = { "above" => 10 }

    assert_equal "scale_out", decide(current: 2, value: 11, above_since: QUIET).action
  end

  test "a signal-driven scale-out waits cooldown.up after the last scale-out" do
    decision = decide(current: 4, value: 20, above_since: QUIET - 300, history: { last_scale_out_at: QUIET - 20 })

    assert_equal [ "hold", [ "cooldown" ] ], [ decision.action, decision.reasons ]
    assert_equal QUIET + 40, decision.eligible_at
    assert_equal "scale_out", decide(current: 4, value: 20, above_since: QUIET - 300, history: { last_scale_out_at: QUIET - 60 }).action
  end

  test "a recent scale-in does not hold a signal-driven scale-out" do
    assert_equal "scale_out", decide(current: 4, value: 20, above_since: QUIET - 300, history: { last_scale_in_at: QUIET - 5 }).action
  end

  test "at scale max × replicas max it holds at_max, and a step never goes past it" do
    assert_equal [ "hold", 8, 8, [ "at_max" ] ], tuple(decide(current: 8, value: 50, above_since: QUIET - 300))
    assert_equal [ "scale_out", 7, 8, [ "above_threshold" ] ], tuple(decide(current: 7, value: 50, above_since: QUIET - 300))
  end

  test "above scale max × replicas max (max lowered under it) it steps down to max, whatever the signal" do
    assert_equal [ "scale_in", 10, 8, [ "at_max" ] ], tuple(decide(current: 10, value: 5))
    assert_equal [ "scale_in", 9, 8, [ "at_max" ] ], tuple(decide(current: 9, value: 50, above_since: QUIET - 300))
    assert_equal [ "scale_in", 9, 8, [ "at_max" ] ], tuple(decide(current: 9, value: nil, error: "Redis down"))

    cooling = decide(current: 9, value: 5, history: { last_scale_in_at: QUIET - 10 })
    assert_equal [ "hold", [ "cooldown" ] ], [ cooling.action, cooling.reasons ]
  end

  test "a step out lands on a count the hosts can split" do
    @scale.merge!("min" => 1, "max" => 4, "step" => 2)
    role = role_with(replicas: 3)

    assert_equal [ "scale_out", 3, 6 ], tuple(decide(role: role, current: 3, value: 20, above_since: QUIET - 300)).first(3)
  end

  test "a guard above its bound holds the scale-out" do
    decision = decide(current: 2, value: 20, above_since: QUIET - 300, guards: [ guard(195) ])

    assert_equal [ "hold", [ "held_by_guard" ] ], [ decision.action, decision.reasons ]
    assert_nil decision.error
    assert_match "held_by_guard: hold_when/0 postgres 195 > 180", decision.summary
  end

  test "a guard that cannot be read holds the scale-out, with its error" do
    decision = decide(current: 2, value: 20, above_since: QUIET - 300, guards: [ guard(nil, error: "PG::ConnectionBad: timeout") ])

    assert_equal [ "hold", [ "held_by_guard" ] ], [ decision.action, decision.reasons ]
    assert_equal "hold_when/0 postgres: PG::ConnectionBad: timeout", decision.error
  end

  test "a guard at its bound does not hold" do
    assert_equal "scale_out", decide(current: 2, value: 20, above_since: QUIET - 300, guards: [ guard(180) ]).action
  end

  test "a guard never holds a scale-out to a schedule floor, nor does a missing sample" do
    decision = decide(now: BILLING, current: 1, value: nil, error: "Redis down", guards: [ guard(500) ])

    assert_equal [ "scale_out", 1, 6, [ "schedule_floor" ] ], tuple(decision)
  end

  test "a missing sample holds the role, above its floor too" do
    decision = decide(current: 4, value: nil, error: "RedisClient::CannotConnectError: connection refused", below_since: QUIET - 3600)

    assert_equal [ "hold", 4, 4, [ "missing_data" ] ], tuple(decision)
    assert_equal "signal sidekiq: RedisClient::CannotConnectError: connection refused", decision.error
  end

  test "no sample at all holds with missing_data" do
    decision = Dash::Autoscale::Policy.new(role: role_with, now: QUIET, time_zone: utc, current: 2).decide

    assert_equal [ "hold", [ "missing_data" ] ], [ decision.action, decision.reasons ]
  end

  test "inside the band it holds, above its floor too" do
    assert_equal [ "hold", 4, 4, [ "at_target" ] ], tuple(decide(current: 4, value: 5))
  end

  test "sustained below the band for down.for, it scales in by a step, never below the floor" do
    decision = decide(current: 5, value: 0.5, below_since: QUIET - 600)
    assert_equal [ "scale_in", 5, 3, [ "below_threshold" ] ], tuple(decision)
    assert_equal "payments: scale_in 5 -> 3 (below_threshold: 0.5 < 2 for 600s)", decision.summary

    assert_equal [ "scale_in", 2, 1, [ "below_threshold" ] ], tuple(decide(current: 2, value: 0.5, below_since: QUIET - 600))
    assert_equal [ "scale_in", 8, 6 ], tuple(decide(now: BILLING, current: 8, value: 0.5, below_since: BILLING - 600)).first(3)
  end

  test "below, but not yet for down.for, it holds until it has been" do
    decision = decide(current: 4, value: 0.5, below_since: QUIET - 100)

    assert_equal [ "hold", [ "below_threshold" ] ], [ decision.action, decision.reasons ]
    assert_equal QUIET + 500, decision.eligible_at
  end

  test "below the band at the floor it holds at_target" do
    assert_equal [ "hold", 1, 1, [ "at_target" ] ], tuple(decide(current: 1, value: 0, below_since: QUIET - 3600))
    assert_equal [ "hold", 6, 6, [ "at_target" ] ], tuple(decide(now: BILLING, current: 6, value: 0, below_since: BILLING - 3600))
  end

  test "a signal-driven scale-in waits for warmup and cooldown.down" do
    warming = decide(current: 4, value: 0, below_since: QUIET - 3600, warming: { "10.0.0.22" => QUIET - 100 })
    assert_equal [ "hold", [ "warming_up" ] ], [ warming.action, warming.reasons ]
    assert_equal QUIET + 200, warming.eligible_at

    cooling = decide(current: 4, value: 0, below_since: QUIET - 3600, history: { last_scale_out_at: QUIET - 100 })
    assert_equal [ "hold", [ "cooldown" ] ], [ cooling.action, cooling.reasons ]
    assert_equal QUIET + 500, cooling.eligible_at
  end

  test "the decision carries the signal, the guards, the breach times and the band" do
    decision = decide(current: 2, value: 12.4, above_since: QUIET - 45, guards: [ guard(10) ])
    inputs = decision.to_h[:inputs]

    assert_equal({ source: "sidekiq", value: 12.4, at: QUIET.iso8601, error: nil }, inputs[:signal])
    assert_equal [ { index: 0, source: "postgres", above: 180, value: 10, at: QUIET.iso8601, error: nil } ], inputs[:guards]
    assert_equal [ (QUIET - 45).iso8601, nil, 10, 30, 2, 600 ], inputs.values_at(:above_since, :below_since, :up_above, :up_for, :down_below, :down_for)
  end

  test "a role without a signal records none of it" do
    @scale = @scale.except("signal", "up", "down", "hold_when")
    inputs = Dash::Autoscale::Policy.new(role: role_with, now: QUIET, time_zone: utc, current: 1).decide.inputs

    assert_not inputs.key?(:signal)
    assert_not inputs.key?(:above_since)
  end

  private
    def decide(current:, value: nil, now: QUIET, error: nil, above_since: nil, below_since: nil, guards: [], role: role_with, **inputs)
      signal = Dash::Autoscale::Sample.new(value: value, at: now, error: error)

      Dash::Autoscale::Policy.new(role: role, now: now, time_zone: utc, current: current, signal: signal, guards: guards,
        breach: { above_since: above_since, below_since: below_since }, **inputs).decide
    end

    def guard(value, error: nil, index: 0)
      Dash::Autoscale::Guard::Reading.new(index: index, source: "postgres", above: 180, sample: Dash::Autoscale::Sample.new(value: value, at: QUIET, error: error))
    end

    def tuple(decision)
      [ decision.action, decision.from, decision.to, decision.reasons ]
    end

    def utc
      ActiveSupport::TimeZone["UTC"]
    end

    def role_with(replicas: { "min" => 1, "max" => 2 }, scale: @scale)
      Dash::Configuration.new({
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: {
          "web" => [ "1.1.1.1" ],
          "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "bundle exec sidekiq", "healthcheck" => false, "replicas" => replicas, "scale" => scale }
        },
        autoscale: { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } },
          "redis" => { "url" => "redis://cache:6379" }, "postgres" => { "url" => "postgres://db/app" } }
      }).role(:payments)
    end
end
