require_relative "diagnostics_test_case"

# The controller's state as dash autoscale explain / history / status and the MCP tools
# read it: from the primary host (1.1.1.1), never crashing on a host that does not answer.
class DiagnosticsAutoscaleTest < DiagnosticsTestCase
  NOW = Time.utc(2026, 10, 14, 21, 0) # 23:00 in Stockholm: inside the payments window

  setup do
    configure :deploy_with_scale_schedule
    Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).returns("")
  end

  test "explain evaluates a role as the next tick would, without acting" do
    stub_state "state.json", JSON.generate("roles" => { "payments" => { "last_scale_out_at" => (NOW - 60).iso8601 } })
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\n"

    explain = Dash::Diagnostics::AutoscaleExplain.new(role: DASH.config.role(:payments), now: NOW).to_h

    assert_equal "payments", explain[:role]
    assert_equal true, explain[:controlled]
    assert_equal "1.1.1.1", explain[:state_host]
    assert_equal "scale_out", explain.dig(:decision, :action)
    assert_equal 6, explain.dig(:decision, :to)
    assert_equal (NOW - 60).iso8601, explain.dig(:decision, :inputs, :last_scale_out_at)
  end

  test "explain names a pause" do
    stub_state "grep -H", %(.dash/apps/app/autoscale/pause/payments.json:{"until":"indefinite","by":"Jane"}\n)
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\n"

    assert_equal [ "paused" ], Dash::Diagnostics::AutoscaleExplain.new(role: DASH.config.role(:payments), now: NOW).to_h.dig(:decision, :reasons)
  end

  test "explain still evaluates when the state cannot be read, and says so" do
    stub_state_unreachable
    stub_capture "1.1.1.2", "{{.Names}}\\t{{.Status}}", "app-payments-123\tUp\n"

    explain = Dash::Diagnostics::AutoscaleExplain.new(role: DASH.config.role(:payments), now: NOW).to_h

    assert_match "ECONNREFUSED", explain[:state_error]
    assert_equal "scale_out", explain.dig(:decision, :action)
  end

  test "explain refuses --hosts, which could leave some of the role's hosts unread" do
    DASH.specific_hosts = [ "1.1.1.2" ]

    error = assert_raises(ArgumentError) { Dash::Diagnostics::AutoscaleExplain.new(role: DASH.config.role(:payments), now: NOW) }
    assert_match "cannot be narrowed with --hosts", error.message
  end

  test "explain refuses a role without scale" do
    error = assert_raises(ArgumentError) { Dash::Diagnostics::AutoscaleExplain.new(role: DASH.config.role(:web), now: NOW) }
    assert_equal "web has no scale, so the autoscale controller never touches it", error.message
  end

  test "decisions reads the tail of the log, of one role or all" do
    line = JSON.generate("role" => "payments", "action" => "scale_out", "from" => 1, "to" => 6, "reasons" => [ "schedule_floor" ])
    SSHKit::Backend::Abstract.any_instance.stubs(:capture)
      .with { |*args| args.join(" ").include?(%(grep -F -e '"role":"payments"')) && args.join(" ").include?("tail -n 20") }.returns("#{line}\n")

    decisions = Dash::Diagnostics::AutoscaleDecisions.new(roles: [ "payments" ], lines: 20).to_h

    assert_equal "1.1.1.1", decisions[:host]
    assert_equal [ "scale_out" ], decisions[:decisions].map { |decision| decision["action"] }
  end

  test "decisions of some roles are filtered on the host before the tail" do
    stub_state %(grep -F -e '"role":"payments"' -e '"role":"reports"'), { "role" => "reports", "action" => "hold" }.to_json

    assert_equal [ "reports" ], Dash::Diagnostics::AutoscaleDecisions.new(roles: [ "payments", "reports" ]).to_h[:decisions].map { |decision| decision["role"] }
  end

  test "status keeps to the run's --roles by default" do
    DASH.specific_roles = [ "reports" ]

    assert_equal [ "reports" ], Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h[:roles]
  end

  test "decisions from a host that does not answer is an error, not a crash" do
    stub_state_unreachable

    assert_match "ECONNREFUSED", Dash::Diagnostics::AutoscaleDecisions.new.to_h[:error]
  end

  test "status: a running controller and the active pauses" do
    stub_state "heartbeat.json", JSON.generate(heartbeat(last_tick_at: (NOW - 4).iso8601))
    stub_state "grep -H", ".dash/apps/app/autoscale/pause/payments.json:#{JSON.generate("until" => (NOW + 3600).iso8601, "by" => "Jane", "at" => NOW.iso8601)}\n" \
      ".dash/apps/app/autoscale/pause/reports.json:#{JSON.generate("until" => (NOW - 1).iso8601)}\n"

    status = Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h

    assert_equal "running", status.dig(:controller, :status)
    assert_equal 4, status.dig(:controller, :age_seconds)
    assert_equal "ops-1", status.dig(:controller, :hostname)
    assert_equal [ "payments", "reports" ], status[:roles]
    assert_equal [ { role: "payments", until: (NOW + 3600).iso8601, by: "Jane", at: NOW.iso8601 } ], status[:pauses]
  end

  test "status: stale, stopped, and never run" do
    stub_state "heartbeat.json", JSON.generate(heartbeat(last_tick_at: (NOW - 31).iso8601))
    assert_equal "stale", Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h.dig(:controller, :status)

    stub_state "heartbeat.json", JSON.generate(heartbeat(last_tick_at: (NOW - 1).iso8601, stopped_at: NOW.iso8601))
    assert_equal "stopped", Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h.dig(:controller, :status)

    stub_state "heartbeat.json", ""
    assert_nil Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h[:controller]
  end

  test "status: a heartbeat that is not JSON is an error, not a controller that never ran" do
    stub_state "heartbeat.json", "{not json"

    status = capture_io { @status = Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h }.then { @status }
    assert_equal "heartbeat.json is not valid JSON", status[:error]
    assert_nil status[:controller]
  end

  test "status keeps to the roles it is given" do
    stub_state "grep -H", ".dash/apps/app/autoscale/pause/payments.json:#{JSON.generate("until" => "indefinite")}\n"

    status = Dash::Diagnostics::ControllerStatus.new(now: NOW, roles: [ DASH.config.role(:reports) ]).to_h

    assert_equal [ "reports" ], status[:roles]
    assert_empty status[:pauses]
  end

  test "status from a host that does not answer is an error, not a crash" do
    stub_state_unreachable

    status = Dash::Diagnostics::ControllerStatus.new(now: NOW).to_h

    assert_equal "1.1.1.1", status[:state_host]
    assert_match "ECONNREFUSED", status[:error]
  end

  private
    def stub_state(fragment, output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture)
        .with { |*args| SSHKit::Backend.current.host.to_s == "1.1.1.1" && args.join(" ").include?(fragment) }.returns(output)
    end

    def stub_state_unreachable
      SSHKit::Backend::Abstract.any_instance.stubs(:capture).with { SSHKit::Backend.current.host.to_s == "1.1.1.1" }.raises(Errno::ECONNREFUSED)
    end

    def heartbeat(**fields)
      { "controller_id" => "abc", "hostname" => "ops-1", "pid" => 42, "version" => "3.9.0", "mode" => "loop", "interval" => 10 }.merge(fields.transform_keys(&:to_s))
    end
end
