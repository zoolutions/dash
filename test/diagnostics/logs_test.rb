require_relative "diagnostics_test_case"

class DiagnosticsLogsTest < DiagnosticsTestCase
  SEPARATOR = "--dash-replica-0123456789abcdef--"

  setup do
    configure :deploy_with_roles
    SecureRandom.stubs(:hex).returns("0123456789abcdef")
  end

  test "tails the role's containers per host and filters with grep locally" do
    commands = []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| commands << args.join(" "); true }
      .returns("#{SEPARATOR}\nGET /up 200\nPOST /orders 500\n")

    snapshot = Dash::Diagnostics::Logs.new(role: DASH.config.role(:web), lines: 50, since: "15m", grep: "500").to_h

    assert_equal "web", snapshot[:role]
    assert_equal [ { host: "1.1.1.1", replicas: [ { replica: 1, lines: [ "POST /orders 500" ] } ] },
                   { host: "1.1.1.2", replicas: [ { replica: 1, lines: [ "POST /orders 500" ] } ] } ], snapshot[:hosts]
    assert commands.all? { |command| command.include?("--since 15m --tail 50 2>&1") && command.start_with?("echo #{SEPARATOR} ;") }
    assert commands.none? { |command| command.include?("grep") }, "grep must never reach the remote shell"
  end

  test "reads every replica slot of a host in one round trip, split on a separator no log can guess" do
    configure :deploy_with_replicas
    captures = []
    separator = SEPARATOR
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| captures << args.join(" "); true }
      .returns("#{separator}\none\n--%--\n#{separator}\ntwo\n#{separator}\n")

    hosts = Dash::Diagnostics::Logs.new(role: DASH.config.role(:payments), lines: 5).to_h[:hosts]

    assert_equal 2, captures.size, "one capture per host"
    assert_equal [ { replica: 1, lines: [ "one", "--%--" ] }, { replica: 2, lines: [ "two" ] }, { replica: 3, lines: [] } ], hosts.first[:replicas]
  end

  test "redacts before grep, so a grep cannot probe a secret" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("#{SEPARATOR}\npassword=hunter2-very-secret\n")
    redactor = Dash::Diagnostics::Redactor.new(secrets: { "PW" => "hunter2-very-secret" })

    probe = Dash::Diagnostics::Logs.new(role: DASH.config.role(:web), hosts: [ "1.1.1.1" ], grep: "hunter2-v", redactor: redactor).to_h
    plain = Dash::Diagnostics::Logs.new(role: DASH.config.role(:web), hosts: [ "1.1.1.1" ], grep: "password", redactor: redactor).to_h

    assert_equal [], probe[:hosts].first[:replicas].first[:lines]
    assert_equal [ "password=[REDACTED]" ], plain[:hosts].first[:replicas].first[:lines]
  end

  test "tails an accessory, with the same validation and local grep" do
    configure :deploy_with_accessories
    commands = []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| commands << args.grep_v(Hash).join(" "); true }.returns("ERROR deadlock\nready\n")

    snapshot = Dash::Diagnostics::Logs.new(accessory: DASH.config.accessory(:mysql), lines: 20, since: "1h", grep: "ERROR").to_h

    assert_equal({ accessory: "mysql", hosts: [ { host: "1.1.1.3", lines: [ "ERROR deadlock" ] } ] }, snapshot.except(:generated_at))
    assert_equal [ "docker logs app-mysql  --since 1h  --tail 20 --timestamps 2>&1" ], commands
  end

  test "never reads a host the role or accessory does not run on, whatever hosts it is given" do
    configure :deploy_with_accessories
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")

    accessory = Dash::Diagnostics::Logs.new(accessory: DASH.config.accessory(:mysql), hosts: [ "1.1.1.1", "1.1.1.3" ]).to_h[:hosts]
    role = Dash::Diagnostics::Logs.new(role: DASH.config.role(:web), hosts: [ "1.1.1.1", "1.1.1.3" ]).to_h[:hosts]

    assert_equal [ "1.1.1.3" ], accessory.map { |host| host[:host] }
    assert_equal [ "1.1.1.1" ], role.map { |host| host[:host] }
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
