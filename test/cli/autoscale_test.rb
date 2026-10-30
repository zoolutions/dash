require_relative "cli_test_case"
require_relative "../autoscale/signal/fakes"
require "tmpdir"

# payments (scale 1-3 hosts, replicas 1-3) has a schedule; the state lives on 1.1.1.1, the
# primary role's first baseline host; the autoscale/controller fixture overrides it with 10.0.0.50.
class CliAutoscaleTest < CliTestCase
  STATE = ".dash/apps/app/autoscale"

  setup do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(members: []))
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).returns("")
  end

  test "run --once starts, ticks once and marks its heartbeat stopped" do
    sequence = sequence("once")
    Dash::Autoscale::Controller.any_instance.expects(:start).in_sequence(sequence)
    Dash::Autoscale::Controller.any_instance.expects(:tick).in_sequence(sequence).returns([])
    Dash::Autoscale::Controller.any_instance.expects(:release).in_sequence(sequence)

    run_command("run", "--once")
  end

  test "run --once fails when its tick does, and still releases" do
    Dash::Autoscale::Controller.any_instance.stubs(:start)
    Dash::Autoscale::Controller.any_instance.stubs(:tick).raises(Dash::Autoscale::LeaseLost, "taken")
    Dash::Autoscale::Controller.any_instance.expects(:release)

    assert_raises(Dash::Autoscale::LeaseLost) { run_command("run", "--once") }
  end

  test "run loops until a signal, with the options it was given" do
    controller = Dash::Autoscale::Controller.allocate
    controller.stubs(id: "abc", interval: 30, metrics: Dash::Autoscale::Metrics.new)
    controller.expects(:run)
    Dash::Autoscale::Controller.expects(:new).with { |**options| options[:dry_run] && options[:interval] == 30 && options[:mode] == "loop" && options[:recorder] }.returns(controller)

    output = run_command("run", "--dry-run", "--interval", "30", "--record", File.join(Dir.mktmpdir, "ticks.jsonl"))
    assert_match "Autoscale controller abc (dry run) ticking every 30s", output
  end

  test "run serves metrics while it loops, and stops serving after" do
    server = Dash::Autoscale::MetricsServer.allocate
    Dash::Autoscale::MetricsServer.expects(:new).with(anything, bind: "127.0.0.1", port: 9394).returns(server)
    server.expects(:start).returns(server)
    server.stubs(:port).returns(9394)
    server.expects(:stop)
    Dash::Autoscale::Controller.any_instance.stubs(:run)

    assert_match "Serving autoscale metrics on http://127.0.0.1:9394/metrics", run_command("run", "--metrics-port", "9394")
  end

  test "TERM asks the loop to stop and the handler is put back after" do
    Dash::Autoscale::Controller.any_instance.stubs(:run).with { Process.kill("TERM", Process.pid); sleep 0.1; true }
    Dash::Autoscale::Controller.any_instance.expects(:stop!)

    previous = trap("TERM", "DEFAULT")
    run_command("run")
    assert_equal "DEFAULT", trap("TERM", previous)
  end

  test "TERM during run --once lets the tick finish" do
    Dash::Autoscale::Controller.any_instance.stubs(:start)
    Dash::Autoscale::Controller.any_instance.stubs(:release)
    Dash::Autoscale::Controller.any_instance.stubs(:tick).with { Process.kill("TERM", Process.pid); sleep 0.1; true }.returns([])
    Dash::Autoscale::Controller.any_instance.expects(:stop!)

    previous = trap("TERM", "DEFAULT")
    run_command("run", "--once")
    assert_equal "DEFAULT", trap("TERM", previous)
  end

  test "run refuses --hosts and too short an interval" do
    assert_match "narrow it with --roles", assert_raises(ArgumentError) { run_command("run", "--hosts", "1.1.1.2") }.message
    assert_match "--interval must be a whole number of seconds, at least 5", assert_raises(ArgumentError) { run_command("run", "--interval", "2") }.message
    assert_match "not 4.9", assert_raises(ArgumentError) { run_command("run", "--interval", "4.9") }.message
  end

  test "scale set runs through dash scale set, waiting for the deploy lock, again and again" do
    stub_scale_set
    stub_running "1.1.1.2" => [ "app-payments-123" ]
    cli = autoscale_cli

    output = stdouted do
      cli.invoke_scale_set(DASH.config.role(:payments), 2)
      cli.invoke_scale_set(DASH.config.role(:payments), 3)
    end

    assert_equal 2, output.scan("Acquiring the deploy lock (waiting up to 30s)").size, output
    assert_match "payments now runs 2 containers on 1 host", output
    assert_match "payments now runs 3 containers on 1 host", output
    assert_equal false, DASH.lock_wait
  end

  test "a failed scale set does not stop the next one" do
    stub_scale_set
    stub_running "1.1.1.2" => [ "app-payments-123" ]
    cli = autoscale_cli
    Dash::Cli::Scale.any_instance.stubs(:scale_out).raises(Dash::Cli::BootError, "unhealthy").then.returns(nil)

    stdouted do
      assert_raises(Dash::Cli::BootError) { cli.invoke_scale_set(DASH.config.role(:payments), 2) }
      cli.invoke_scale_set(DASH.config.role(:payments), 2)
    end
  end

  test "an unreachable member is replaced through dash scale's replacement, waiting for the lock" do
    cli = autoscale_cli
    member = Dash::Autoscale::Member.new(id: "m1", host: "10.0.0.22", role: "payments", state: "started")
    Dash::Cli::Scale.any_instance.expects(:replace_unreachable).with { |role, replaced, count:| DASH.lock_wait && role.name == "payments" && replaced == member && count == 3 }

    cli.replace_member(DASH.config.role(:payments), member, count: 3)
  end

  test "reconfigure reads deploy.yml again and keeps --roles" do
    cli = autoscale_cli("roles" => "payments")
    old = DASH.config

    cli.reconfigure!

    assert_not_same old, DASH.config
    assert_equal [ "payments" ], DASH.specific_roles.map(&:name)
  end

  test "explain prints the decision and every input" do
    stub_running_status "1.1.1.2", "app-payments-123\tUp\n"

    output = run_command("explain", "payments")

    assert_match(/payments: (hold|scale_out) 1 -> \d+/, output)
    assert_match "  floor: ", output
    assert_match "  step: 3", output
  end

  test "explain --json is the diagnostic" do
    stub_running_status "1.1.1.2", "app-payments-123\tUp\n"

    explain = JSON.parse(run_command("explain", "payments", "--json"))

    assert_equal "payments", explain["role"]
    assert_equal 1, explain.dig("decision", "from")
  end

  test "explain refuses a role without scale" do
    assert_match "web has no scale", assert_raises(ArgumentError) { run_command("explain", "web") }.message
  end

  test "signal prints one live sample of the signal and of each guard, and where it was read from" do
    stub_signal_sources
    output = run_command("signal", "payments", config: :with_scale_signal)

    assert_match %r{payments: sidekiq 12\.5, above the band \(up above 10 for 30s, down below 2 for 600s\), read from laptop in [\d.]+ms}, output
    assert_match %r{  hold_when/0 postgres 195\.0 > 180, holding a scale-out \([\d.]+ms\)}, output
  end

  test "signal --json is the diagnostic" do
    stub_signal_sources
    signal = JSON.parse(run_command("signal", "payments", "--json", config: :with_scale_signal))

    assert_equal [ "payments", "sidekiq", 12.5 ], [ signal["role"], signal.dig("signal", "source"), signal.dig("signal", "value") ]
  end

  test "signal runs the pre-connect hook first, as a via: tunnel opens SSH" do
    stub_signal_sources
    order = sequence("pre-connect, then read")
    Dash::Cli::Autoscale.any_instance.expects(:pre_connect_if_required).in_sequence(order)
    Dash::Autoscale::Signal::Sidekiq.any_instance.expects(:sample).in_sequence(order).returns(Dash::Autoscale::Sample.new(value: 1, at: Time.now.utc))

    run_command("signal", "payments", config: :with_scale_signal)
  end

  test "signal on a proxy role prints the unit, the traffic, and each host's share" do
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
    Socket.stubs(:gethostname).returns("laptop")
    buckets = [ 10.0, 25.0, 50.0, 100.0 ].zip([ 0, 0, 30, 30 ])
    Dash::Diagnostics::ProxyQueue.any_instance.stubs(:to_h).returns(role: "web", hosts: [
      { host: "1.1.1.1", targets: [ { address: "a:80", window_seconds: 60, requests: 30, app: 30, proxy: 0, buckets: buckets } ] },
      { host: "1.1.1.2", error: "Errno::ECONNREFUSED: Connection refused" } ])

    output = run_command("signal", "web", config: :with_scale_proxy_signal)

    assert_match %r{web: proxy 48\.8ms, inside the band \(up above 50 for 30s, down below 25 for 600s\), read from laptop in [\d.]+ms}, output
    assert_match "  30 requests in the last 60s, queue time from the app 30, from dash-proxy's connection wait 0", output
    assert_match "  1.1.1.1: 30 requests, p95 48.8ms", output
    assert_match "  1.1.1.2: did not answer: Errno::ECONNREFUSED: Connection refused", output

    signal = JSON.parse(run_command("signal", "web", "--json", config: :with_scale_proxy_signal))["signal"]
    assert_equal [ "proxy", 48.8, "ms" ], [ signal["source"], signal["value"], signal.dig("detail", "unit") ]
  end

  test "signal on a proxy role no host answers names each host and no traffic" do
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
    Socket.stubs(:gethostname).returns("laptop")
    Dash::Diagnostics::ProxyQueue.any_instance.stubs(:to_h).returns(role: "web", hosts: [ { host: "1.1.1.1", error: "no answer" }, { host: "1.1.1.2", error: "no answer" } ])

    output = run_command("signal", "web", config: :with_scale_proxy_signal)

    assert_match "web: proxy could not be read from laptop: RuntimeError: no dash-proxy of web answered: 1.1.1.1 (no answer), 1.1.1.2 (no answer)", output
    assert_match "  1.1.1.2: did not answer: no answer", output
    assert_no_match "requests in the last", output
  end

  test "signal on a role without one says so" do
    assert_match "reports has no scale/signal, so there is nothing to sample", run_command("signal", "reports", config: :with_scale_signal)
  end

  test "signal shows a source that cannot be read" do
    Dash::Autoscale::Connections.stubs(:new).returns(AutoscaleSignalFakes::Connections.new(redis: Errno::ECONNREFUSED.new("cache.internal:6379"),
      postgres: AutoscaleSignalFakes::Postgres.new("SELECT count(*) FROM pg_stat_activity" => "4")))
    Socket.stubs(:gethostname).returns("laptop")

    output = run_command("signal", "payments", config: :with_scale_signal)
    assert_match "payments: sidekiq could not be read from laptop: Errno::ECONNREFUSED: Connection refused - cache.internal:6379", output
    assert_match %r{  hold_when/0 postgres 4\.0 \(}, output
  end

  test "simulate replays a recorded file with deploy.yml's thresholds: every simulated action, then a summary per role" do
    output = run_command("simulate", "--samples", record_file, config: :with_scale_signal)

    assert_match "2026-10-15T02:00:30Z payments: scale_out 1 -> 3 (above_threshold: 20 > 10 for 30s)", output
    assert_match "payments: 13 ticks, 13 replayed", output
    assert_match "2026-10-15T02:01:30Z payments: scale_out 3 -> 5 (above_threshold: 20 > 10 for 90s)", output
    assert_match "  simulated: 2 scale-outs, 0 scale-ins, peak 5, minimum 1, 360 container-seconds", output
    assert_match "  recorded:  0 scale-outs, 0 scale-ins, peak 1, minimum 1, 120 container-seconds", output
  end

  test "simulate --json is the simulation" do
    simulation = JSON.parse(run_command("simulate", "--samples", record_file, "--json", config: :with_scale_signal))

    assert_equal [ "payments" ], simulation["roles"].map { |role| role["role"] }
    assert_equal [ "scale_out", "scale_out" ], simulation.dig("roles", 0, "actions").map { |action| action["action"] }
  end

  test "simulate says what it could not replay" do
    path = record_file(extra: [ "{oops", JSON.generate(at: "2026-10-15T02:03:00Z", decisions: [ { role: "payments", action: "hold", from: 3, to: 3, reasons: [ "at_target" ], inputs: { current: 3 } } ]) ])
    output = run_command("simulate", "--samples", path, config: :with_scale_signal)

    assert_match "  1 tick not replayable: recorded without a signal (before Phase 3), or not evaluated", output
    assert_match %r{line 14: }, output
  end

  test "simulate keeps to --roles" do
    output = run_command("simulate", "--samples", record_file, "--roles", "web", config: :with_scale_signal)

    assert_no_match "payments", output
    assert_match "No role in ", output
  end

  test "simulate says when a role had no tick it could replay" do
    path = File.join(Dir.mktmpdir, "record.jsonl")
    File.write(path, JSON.generate(at: "2026-10-15T02:00:00Z", decisions: [ { role: "payments", action: "hold", reasons: [ "action_failed" ], inputs: {} } ]) + "\n")

    assert_match "  simulated: no tick replayed", run_command("simulate", "--samples", path, config: :with_scale_signal)
  end

  test "simulate needs a file that exists" do
    assert_match "No such file: missing.jsonl", assert_raises(ArgumentError) { run_command("simulate", "--samples", "missing.jsonl") }.message
  end

  test "history prints the decisions, oldest first" do
    stub_state "tail -n 50", [ { "at" => "2026-10-14T20:00:00Z", "role" => "payments", "action" => "scale_out", "from" => 1, "to" => 6, "reasons" => [ "schedule_floor" ] },
      { "at" => "2026-10-14T20:00:10Z", "role" => "payments", "action" => "hold", "from" => 6, "to" => 6, "reasons" => [ "lock_busy" ], "error" => "Timed out" } ].map(&:to_json).join("\n")

    output = run_command("history")

    scale_out = output.index("2026-10-14T20:00:00Z  payments: scale_out 1 -> 6 (schedule_floor)")
    hold = output.index("2026-10-14T20:00:10Z  payments: hold 6 -> 6 (lock_busy) - Timed out")
    assert scale_out && hold, output
    assert_operator scale_out, :<, hold, "oldest first"
  end

  test "history of one role, as JSON" do
    stub_state %(grep -F -e '"role":"payments"'), { "role" => "payments", "action" => "hold" }.to_json

    assert_equal [ "hold" ], JSON.parse(run_command("history", "payments", "--lines", "5", "--json"))["decisions"].map { |decision| decision["action"] }
  end

  test "status prints the controller and the pauses" do
    stub_state "heartbeat.json", { "controller_id" => "abc", "hostname" => "ops-1", "pid" => 42, "version" => "3.9.0", "mode" => "loop", "interval" => 10,
      "last_tick_at" => Time.now.utc.iso8601 }.to_json
    stub_state "grep -H", "#{STATE}/pause/payments.json:#{{ "until" => "indefinite", "by" => "Jane" }.to_json}\n"

    output = run_command("status")

    assert_match(/Controller abc on ops-1 \(pid 42, dash 3\.9\.0, loop\): running, last tick \d+s ago/, output)
    assert_match "Scheduled roles: payments", output
    assert_match "payments paused until resumed by Jane", output
  end

  test "status without a controller" do
    assert_match "No autoscale controller has run for this app", run_command("status")
  end

  test "pause writes the pause file and an audit line on the primary host" do
    Dash::Git.stubs(:user_name).returns("Jane")

    output = run_command("pause", "payments", "--for", "2h")

    assert_match(%r{mkdir -p #{STATE}/pause on 1\.1\.1\.1}, output)
    assert_match(%r{base64 -d > #{STATE}/pause/payments\.json\.tmp && mv #{STATE}/pause/payments\.json\.tmp #{STATE}/pause/payments\.json on 1\.1\.1\.1}, output)
    assert_match(/Paused autoscaling of payments until \d{4}-\d\d-\d\dT/, output)
    encoded = output[/echo "([A-Za-z0-9+\/=]+)" \| base64 -d > #{STATE}\/pause/, 1]
    assert_equal "Jane", JSON.parse(Base64.decode64(encoded))["by"]
  end

  test "pause and resume write to autoscale/controller when it is set, never to the primary host" do
    output = run_command("pause", "payments", config: :with_scale_controller) + run_command("resume", "payments", config: :with_scale_controller)

    assert_match(%r{mv #{STATE}/pause/payments\.json\.tmp #{STATE}/pause/payments\.json on 10\.0\.0\.50}, output)
    assert_match(%r{rm -f #{STATE}/pause/payments\.json on 10\.0\.0\.50}, output)
    assert_no_match(%r{#{STATE}\S* on 1\.1\.1\.1}, output)
  end

  test "pause and resume keep their audit lines on the primary host, where dash audit reads them" do
    output = run_command("pause", "payments", "-v", config: :with_scale_controller) + run_command("resume", "payments", "-v", config: :with_scale_controller)

    assert_match(/Paused autoscaling of payments until resumed.*audit\.log on 1\.1\.1\.1/, output)
    assert_match(/Resumed autoscaling of payments.*audit\.log on 1\.1\.1\.1/, output)
    assert_no_match(/audit\.log on 10\.0\.0\.50/, output)
  end

  test "pause without --for holds until resumed" do
    assert_match "Paused autoscaling of payments until resumed", run_command("pause", "payments")
  end

  test "pause refuses a role without scale and a duration that is not one" do
    assert_match "web has no scale", assert_raises(ArgumentError) { run_command("pause", "web") }.message
    assert_match "should be seconds", assert_raises(ArgumentError) { run_command("pause", "payments", "--for", "soon") }.message
    assert_match "longer than 0 seconds", assert_raises(ArgumentError) { run_command("pause", "payments", "--for", "0") }.message
  end

  test "resume removes the pause file" do
    output = run_command("resume", "payments")

    assert_match "rm -f #{STATE}/pause/payments.json on 1.1.1.1", output
    assert_match "Resumed autoscaling of payments", output
  end

  test "is a subcommand of dash" do
    assert_match "autoscale run", stdouted { Dash::Cli::Main.start([ "autoscale", "help" ]) }
  end

  private
    def run_command(*command, config: :with_scale_schedule)
      stdouted { Dash::Cli::Autoscale.start([ *command, "-c", "test/fixtures/deploy_#{config}.yml" ]) }
    end

    def autoscale_cli(options = {})
      Dash::Cli::Autoscale.new([], { "config_file" => "test/fixtures/deploy_with_scale_schedule.yml" }.merge(options), invocations: Hash.new { |hash, key| hash[key] = [] }.merge(Dash::Cli::Autoscale => [ "run" ])).tap do
        DASH.config
      end
    end

    # A replica boot that works, as in test/cli/scale_hosts_test.rb.
    def stub_scale_set
      Object.any_instance.stubs(:sleep)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123")
      stub_readiness_wait "no-healthcheck:running"
      stub_readiness_confirm "no-healthcheck:running"
      stub_run_capture
    end

    # payments at 1 container, its oldest job 20s old, a tick every 10 seconds for 2 minutes.
    def record_file(extra: [])
      path = File.join(Dir.mktmpdir, "record.jsonl")
      lines = (0..120).step(10).map do |offset|
        at = (Time.utc(2026, 10, 15, 2, 0, 0) + offset).iso8601
        inputs = { current: 1, signal: { source: "sidekiq", value: 20, at: at, error: nil }, guards: [ { index: 0, source: "postgres", above: 180, value: 4, at: at, error: nil } ] }
        JSON.generate(at: at, decisions: [ { role: "payments", action: "hold", from: 1, to: 1, reasons: [ "at_target" ], inputs: inputs } ])
      end
      File.write(path, (lines + extra).join("\n") + "\n")
      path
    end

    # The clock stands still, so the job is exactly 12.5 seconds old when it is read.
    def stub_signal_sources
      travel_to Time.utc(2026, 10, 15, 2, 0, 0)
      redis = AutoscaleSignalFakes::Redis.new([ "LINDEX", "queue:payments", -1 ] => JSON.generate("enqueued_at" => Time.now.to_f - 12.5))
      postgres = AutoscaleSignalFakes::Postgres.new("SELECT count(*) FROM pg_stat_activity" => "195")
      Dash::Autoscale::Connections.stubs(:new).returns(AutoscaleSignalFakes::Connections.new(redis: redis, postgres: postgres))
      Socket.stubs(:gethostname).returns("laptop")
    end

    def stub_state(fragment, output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture)
        .with { |*args| SSHKit::Backend.current.host.to_s == "1.1.1.1" && args.join(" ").include?(fragment) }.returns(output)
    end

    def stub_running(names_by_host)
      names_by_host.each do |host, names|
        SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
          .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?("--format \"{{.Names}}\"") }
          .returns(names.join("\n") + "\n")
      end
    end

    def stub_running_status(host, output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?("{{.Names}}\\t{{.Status}}") }.returns(output)
    end
end
