require_relative "diagnostics_test_case"

class DiagnosticsLogsTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "tails the role's containers per host and filters with grep locally" do
    commands = []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| commands << args.join(" "); true }
      .returns("GET /up 200\nPOST /orders 500\n")

    snapshot = Dash::Diagnostics::Logs.new(role: DASH.config.role(:web), lines: 50, since: "15m", grep: "500").to_h

    assert_equal "web", snapshot[:role]
    assert_equal [ { host: "1.1.1.1", replicas: [ { replica: 1, lines: [ "POST /orders 500" ] } ] },
                   { host: "1.1.1.2", replicas: [ { replica: 1, lines: [ "POST /orders 500" ] } ] } ], snapshot[:hosts]
    assert commands.all? { |command| command.include?("--since 15m --tail 50 2>&1") }
    assert commands.none? { |command| command.include?("grep") }, "grep must never reach the remote shell"
  end

  test "refuses a since that is not a duration or a timestamp" do
    [ "5m; touch /tmp/pwned", "$(id)", "`id`", "yesterday" ].each do |since|
      assert_raises(ArgumentError, since) { Dash::Diagnostics::Logs.new(since: since) }
    end

    %w[ 42m 1h30m 2026-10-05 2026-10-05T10:00:00Z 2026-10-05T10:00:00+02:00 ].each do |since|
      assert_nothing_raised { Dash::Diagnostics::Logs.new(since: since) }
    end
  end

  test "bounds lines and grep" do
    assert_raises(ArgumentError) { Dash::Diagnostics::Logs.new(lines: 501) }
    assert_raises(ArgumentError) { Dash::Diagnostics::Logs.new(grep: "x" * 201) }
  end
end
