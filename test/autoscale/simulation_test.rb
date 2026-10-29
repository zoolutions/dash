require "test_helper"
require "tmpdir"

# payments: replicas 1-2 on 1 to 4 hosts (1 to 8 containers), a Sidekiq signal held between
# 2 and 10 seconds (up after 30s, down after 600s), step 2, cooldown up 60 / down 600, no
# warmup, a Postgres guard above 180. A recorded billing ramp: a tick every 10 seconds from
# T, the oldest job 20s old for the first 100s, then 0.5s until T + 1400; the role ran 2
# containers throughout and the guard read 40.
class AutoscaleSimulationTest < ActiveSupport::TestCase
  T = Time.utc(2026, 10, 15, 2, 0, 0)

  setup do
    @scale = { "min" => 1, "max" => 4, "step" => 2, "warmup" => 0, "cooldown" => { "up" => 60, "down" => 600 },
      "signal" => { "source" => "sidekiq", "queues" => [ "default" ] }, "up" => { "above" => 10, "for" => 30 }, "down" => { "below" => 2, "for" => 600 },
      "hold_when" => [ { "source" => "postgres", "query" => "SELECT count(*) FROM pg_stat_activity", "above" => 180 } ] }
    @dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "a recorded billing ramp: steps up once up.for has passed, then down after down.for and each cooldown" do
    result = simulate(ramp)

    assert_equal [ [ 30, "scale_out", 2, 4 ], [ 90, "scale_out", 4, 6 ], [ 710, "scale_in", 6, 4 ], [ 1310, "scale_in", 4, 2 ] ], actions(result)
    assert_equal [ 141, 141, 0 ], payments(result).values_at(:ticks, :replayed, :not_replayable)
  end

  test "the current thresholds decide, not the recorded ones" do
    @scale["up"] = { "above" => 30, "for" => 30 }

    assert_equal [ [ 710, "scale_in", 2, 1 ] ], actions(simulate(ramp))
  end

  test "a recorded guard reading holds against the current bound" do
    assert_empty actions(simulate(ramp(guard: 195))).select { |_, action| action == "scale_out" }

    @scale["hold_when"].first["above"] = 200
    assert_equal 2, actions(simulate(ramp(guard: 195))).count { |_, action| action == "scale_out" }
  end

  test "a guard the recording does not have is left out, and counted" do
    @scale["hold_when"] << { "source" => "postgres", "query" => "SELECT 2", "above" => 1 }

    result = simulate(ramp)
    assert_equal 2, actions(result).count { |_, action| action == "scale_out" }
    assert_equal 1, payments(result)[:unrecorded_guards]
  end

  test "a guard whose source changed since the recording is not replayed against the new one" do
    @scale["hold_when"] = [ { "source" => "prometheus", "query" => "max(x)", "above" => 100 } ]

    result = simulate(ramp(guard: 195))
    assert_equal 2, actions(result).count { |_, action| action == "scale_out" }
    assert_equal 1, payments(result)[:unrecorded_guards]
  end

  test "a role with a schedule and no signal is replayed too: its floor needs no sample" do
    @scale = @scale.except("signal", "up", "down", "hold_when").merge("schedule" => [ { "cron" => "0 2 15 * *", "for" => "10m", "min" => 6 } ])

    assert_equal [ [ 0, "scale_out", 2, 6 ], [ 600, "scale_in", 6, 4 ], [ 1200, "scale_in", 4, 2 ] ], actions(simulate(ramp))
  end

  test "a role with no replayable tick holds its recorded count throughout" do
    result = simulate(ramp.map { |line| without_signal(line) })

    assert_equal [ 0, 141 ], payments(result).values_at(:replayed, :not_replayable)
    assert_equal({ scale_outs: 0, scale_ins: 0, peak: 2, minimum: 2, container_seconds: 2800 }, payments(result)[:simulated])
  end

  test "a recorded unreachable member holds the simulation too" do
    lines = ramp.map { |line| JSON.generate(JSON.parse(line).tap { |tick| tick["decisions"].first["inputs"]["unreachable"] = { "10.0.0.22" => tick["at"] } }) }

    assert_empty actions(simulate(lines))
  end

  test "the count and the last scale times come from the first tick that has them, never a later one" do
    lines = ramp.map { |line| JSON.generate(JSON.parse(line).tap { |tick| tick["decisions"].first["inputs"]["last_scale_out_at"] = (T + 5).iso8601 }) }
    lines[0] = JSON.generate(at: T.iso8601, decisions: [ { role: "payments", action: "hold", reasons: [ "action_failed" ], inputs: {}, error: "boom" } ])
    result = simulate(lines)

    assert_equal [ 70, "scale_out", 2, 4 ], actions(result).first, "cooldown.up from the scale-out recorded at T+5"
    assert_equal [ 141, 140, 1 ], payments(result).values_at(:ticks, :replayed, :not_replayable)
  end

  test "a scale-out onto new hosts warms them up, which holds a scale-in" do
    @scale["warmup"] = 1000

    assert_equal [ [ 30, "scale_out", 2, 4 ], [ 90, "scale_out", 4, 6 ], [ 1090, "scale_in", 6, 4 ] ], actions(simulate(ramp))
  end

  test "a summary per role, simulated and recorded: actions, peak, minimum and container-seconds" do
    summary = payments(simulate(ramp))

    assert_equal({ scale_outs: 2, scale_ins: 2, peak: 6, minimum: 2, container_seconds: 6600 }, summary[:simulated])
    assert_equal({ scale_outs: 0, scale_ins: 0, peak: 2, minimum: 2, container_seconds: 2800 }, summary[:recorded])
  end

  test "a recorded pause holds the simulation too" do
    result = simulate(ramp(paused_until: "indefinite"))

    assert_empty actions(result)
  end

  test "ticks recorded without a signal (before Phase 3) are not replayable, and keep the count" do
    lines = ramp.each_with_index.map { |line, index| index < 10 ? without_signal(line) : line }
    result = simulate(lines)

    assert_equal [ 141, 131, 10 ], payments(result).values_at(:ticks, :replayed, :not_replayable)
    assert_equal [ [ 710, "scale_in", 2, 1 ] ], actions(result), "the above-band run left only 100 to 110 replayable, shorter than up.for"
  end

  test "a malformed line is reported with its line number, and the rest is replayed" do
    lines = ramp
    lines[1] = "{not json"
    lines[2] = JSON.generate(at: "yesterday")
    result = simulate(lines)

    assert_equal [ 2, 3 ], result[:errors].map { |error| error[:line] }
    assert_match "line is not a recorded tick", result[:errors].last[:error]
    assert_equal 139, payments(result)[:ticks]
  end

  test "a role the current deploy.yml does not control is skipped, with why" do
    lines = ramp.map { |line| JSON.generate(JSON.parse(line).tap { |tick| tick["decisions"] << tick["decisions"].first.merge("role" => "web") }) }

    assert_equal [ { role: "web", reason: "web has no scale/schedule or scale/signal in deploy.yml" } ], simulate(lines)[:skipped]
  end

  test "keeps to the roles asked for" do
    assert_empty simulate(ramp, roles: [ "web" ])[:roles]
  end

  private
    # One recorded tick every 10 seconds, T to T + 1400.
    def ramp(guard: 40, paused_until: nil)
      (0..1400).step(10).map do |offset|
        at = T + offset
        value = offset <= 100 ? 20 : 0.5
        inputs = { current: 2, last_scale_out_at: nil, last_scale_in_at: nil, paused_until: paused_until,
          signal: { source: "sidekiq", value: value, at: at.iso8601, error: nil },
          guards: [ { index: 0, source: "postgres", above: 180, value: guard, at: at.iso8601, error: nil } ] }

        JSON.generate(at: at.iso8601, decisions: [ { role: "payments", action: "hold", from: 2, to: 2, reasons: [ "at_target" ], inputs: inputs, at: at.iso8601 } ])
      end
    end

    def without_signal(line)
      JSON.generate(JSON.parse(line).tap { |tick| tick["decisions"].each { |decision| decision["inputs"] = decision["inputs"].except("signal", "guards") } })
    end

    def simulate(lines, roles: nil)
      path = File.join(@dir, "record.jsonl")
      File.write(path, lines.join("\n") + "\n")

      Dash::Autoscale::Simulation.new(path: path, config: config, roles: roles).run
    end

    def payments(result)
      result[:roles].find { |role| role[:role] == "payments" }
    end

    def actions(result)
      payments(result).to_h.fetch(:actions, []).map { |decision| [ Time.iso8601(decision[:at]) - T, decision[:action], decision[:from], decision[:to] ] }
    end

    def config
      Dash::Configuration.new({
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, builder: { "arch" => "amd64" },
        servers: { "web" => [ "1.1.1.1" ],
          "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "bundle exec sidekiq", "healthcheck" => false, "replicas" => { "min" => 1, "max" => 2 }, "scale" => @scale } },
        autoscale: { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } },
          "redis" => { "url" => "redis://cache:6379" }, "postgres" => { "url" => "postgres://db/app" }, "prometheus" => { "url" => "http://10.0.0.9:9090" } }
      })
    end
end
