require_relative "cli_test_case"

class CliAppReplicasTest < CliTestCase
  SEPARATOR = Dash::Commands::App::BOOT_STATE_SEPARATOR

  setup do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123")
    stub_readiness_wait "no-healthcheck:running"
    stub_readiness_confirm "no-healthcheck:running"
    stub_run_capture
  end

  test "boot swaps every replica of a proxied role behind one dash-proxy deploy" do
    stub_boot_states running: { 1 => "123", 2 => "123" }
    stub_run_capture_ids "aaaaaaaaaaaa1111", "bbbbbbbbbbbb2222"

    run_command("boot").tap do |output|
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} --env KAMAL_CONTAINER_NAME="app-web-latest" .* --env DASH_REPLICA="1" .* --label replica="1" /, output
      assert_match /docker run --detach --restart unless-stopped --name app-web.2-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} --env KAMAL_CONTAINER_NAME="app-web.2-latest" .* --env DASH_REPLICA="2" .* --label replica="2" /, output

      assert_equal 1, output.scan("dash-proxy deploy app-web ").size, output
      assert_match 'dash-proxy deploy app-web --target="aaaaaaaaaaaa:80,bbbbbbbbbbbb:80"', output

      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
      assert_match "docker container ls --all --filter 'name=^app-web.2-123$' --quiet | xargs docker stop", output
      assert output.index("dash-proxy deploy app-web ") < output.index("'name=^app-web-123$' --quiet | xargs docker stop"), output
    end
  end

  test "boot raises a role to min when fewer replicas run" do
    stub_boot_states running: { 1 => "123" }

    run_command("boot").tap do |output|
      assert_match "--name app-web-latest ", output
      assert_match "--name app-web.2-latest ", output
    end
  end

  test "boot keeps the runtime count of a worker between min and max" do
    stub_boot_states running: { 1 => "123", 2 => "123" }, role: :payments

    run_command("boot", host: "1.1.1.2").tap do |output|
      assert_match "--name app-payments-latest ", output
      assert_match "--name app-payments.2-latest ", output
      assert_no_match(/app-payments\.3-latest/, output)
    end
  end

  test "boot with nothing running boots min" do
    stub_boot_states running: {}, role: :payments

    run_command("boot", host: "1.1.1.2").tap do |output|
      assert_match "--name app-payments-latest ", output
      assert_no_match(/app-payments\.2-latest/, output)
      assert_no_match(/xargs docker stop/, output)
    end
  end

  test "boot caps the count at max and stops the replicas above it" do
    stub_boot_states running: { 1 => "123", 2 => "123", 3 => "123", 4 => "123" }, role: :payments

    run_command("boot", host: "1.1.1.2").tap do |output|
      assert_match "--name app-payments.3-latest ", output
      assert_no_match(/--name app-payments\.4-latest/, output)
      assert_match "docker container ls --all --filter 'name=^app-payments.4-123$' --quiet | xargs docker stop -t 45", output
    end
  end

  test "boot waits for every worker replica to be ready" do
    stub_boot_states running: { 1 => "123", 2 => "123" }, role: :payments

    captures = recorded_captures { run_command("boot", host: "1.1.1.2") }

    waits = captures.select { |capture| capture.include?(Dash::Commands::Base::READINESS_PROGRESS_PREFIX) }
    assert_equal 2, waits.size, captures.inspect
    assert_match "name=^app-payments-latest$", waits.first
    assert_match "name=^app-payments.2-latest$", waits.last
  end

  test "boot renames a clashing container in each slot" do
    stub_boot_states running: { 1 => "latest", 2 => "latest" }, clashes: { 1 => "c1", 2 => "c2" }

    run_command("boot").tap do |output|
      renamed_1 = output[/docker rename app-web-latest (app-web-latest_replaced_[0-9a-f]{16})/, 1]
      renamed_2 = output[/docker rename app-web.2-latest (app-web.2-latest_replaced_[0-9a-f]{16})/, 1]
      assert renamed_1, output
      assert renamed_2, output

      assert_match "'name=^#{renamed_1}$' --quiet | xargs docker stop", output
      assert_match "'name=^#{renamed_2}$' --quiet | xargs docker stop", output
    end
  end

  test "boot fires the proxy deploy hooks once and the app stop hooks once per old container" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    stub_boot_states running: { 1 => "123", 2 => "123" }

    run_command("boot").tap do |output|
      assert_hook_ran "pre-proxy-deploy", output, count: 1
      assert_equal 1, output.scan("hooks/pre-proxy-deploy").size, output
      assert_equal 2, output.scan("hooks/pre-app-stop").size, output
      assert_equal 2, output.scan("hooks/post-app-stop").size, output
    end
  end

  test "a failed boot stops every new replica and leaves the old ones running" do
    Thread.report_on_exception = false
    stub_boot_states running: { 1 => "123", 2 => "123" }

    executions = []
    SSHKit::Backend::Abstract.any_instance.stubs(:execute).with { |*args| executions << args.join(" "); !args.join(" ").include?("dash-proxy deploy") }
    SSHKit::Backend::Abstract.any_instance.stubs(:execute).with { |*args| args.join(" ").include?("dash-proxy deploy") }
      .raises(SSHKit::Command::Failed.new("unhealthy"))

    run_command("boot", allow_execute_error: true)

    assert executions.any? { |command| command.include?("'name=^app-web-latest$' --quiet | xargs docker stop") }, executions.inspect
    assert executions.any? { |command| command.include?("'name=^app-web.2-latest$' --quiet | xargs docker stop") }, executions.inspect
    assert executions.none? { |command| command.include?("'name=^app-web-123$'") }, executions.inspect
  ensure
    Thread.report_on_exception = true
  end

  test "a role without replicas stops a slot left over from when it had them" do
    stub_boot_state_output "\n#{SEPARATOR}\n123\n#{SEPARATOR}\napp-workers-123\napp-workers.2-123\n"

    run_command("boot", config: :with_accessories, host: "1.1.1.3").tap do |output|
      assert_match "--name app-workers-latest ", output
      assert_no_match(/--name app-workers\.2-latest/, output)
      assert_no_match(/DASH_REPLICA/, output)
      assert_match "docker container ls --all --filter 'name=^app-workers-123$' --quiet | xargs docker stop", output
      assert_match "docker container ls --all --filter 'name=^app-workers.2-123$' --quiet | xargs docker stop", output
    end
  end

  test "slot 1's version comes from the container names when --latest read another slot" do
    stub_boot_state_output "\n#{SEPARATOR}\napp-workers.2-123\n#{SEPARATOR}\napp-workers-122\napp-workers.2-123\n"

    run_command("boot", config: :with_accessories, host: "1.1.1.3").tap do |output|
      assert_match "docker container ls --all --filter 'name=^app-workers-122$' --quiet | xargs docker stop", output
      assert_match "docker container ls --all --filter 'name=^app-workers.2-123$' --quiet | xargs docker stop", output
    end
  end

  test "boot records the replica count on the host's timing entry" do
    stub_boot_states running: { 1 => "123", 2 => "123" }

    run_command("boot")

    assert DASH.timings.lines.any? { |line| line.match?(/web 1\.1\.1\.1 .*\(healthy after \d+\.\ds, 2 replicas\)\z/) }, DASH.timings.lines.inspect
  end

  test "boot says how many replicas it boots and how many were running" do
    stub_boot_states running: { 1 => "123" }, role: :payments

    assert_match "Booting 1 replica of payments on 1.1.1.2 (1 of 3 slots running, min 1)", run_command("boot", host: "1.1.1.2")
  end

  test "start starts every slot and registers every running replica" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("999")

    run_command("start").tap do |output|
      assert_match "docker start app-web-999", output
      assert_match "docker start app-web.2-999", output
      assert_match 'dash-proxy deploy app-web --target="999:80,999:80"', output
    end
  end

  test "stop removes the service once and stops every slot" do
    run_command("stop").tap do |output|
      assert_equal 1, output.scan("dash-proxy remove app-web").size, output
      assert_match "--filter '\\''name=^app-web-'\\'' --filter status=running --filter status=restarting' | head -1 | xargs docker stop", output
      assert_match "--filter '\\''name=^app-web\\.2-'\\'' --filter status=running --filter status=restarting' | head -1 | xargs docker stop", output
    end
  end

  test "logs shows every replica under its own header" do
    run_command("logs").tap do |output|
      assert_match "App (replica 1) Host: 1.1.1.1", output
      assert_match "App (replica 2) Host: 1.1.1.1", output
    end
  end

  test "logs --replica shows one replica" do
    run_command("logs", "--replica", "2").tap do |output|
      assert_match "App (replica 2) Host: 1.1.1.1", output
      assert_no_match(/replica 1\)/, output)
    end
  end

  test "exec --reuse --replica runs in that slot's container" do
    captures = recorded_captures { run_command("exec", "--reuse", "--replica", "2", "ruby -v") }

    assert captures.any? { |capture| capture.start_with?("docker exec app-web.2-123 ruby -v") }, captures.inspect
  end

  test "stale_containers checks every slot" do
    captures = recorded_captures { run_command("stale_containers") }

    stale_states = captures.select { |capture| capture.include?(Dash::Commands::App::BOOT_STATE_SEPARATOR) }
    assert_equal 2, stale_states.size, captures.inspect
    assert_match "${line#app-web.2-}", stale_states.last
  end

  test "rollout deploy boots as many replicas as run and targets them all" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("'name=^app-web-latest$'") && args.last == { raise_on_non_zero_exit: false } }
      .returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("--format \"{{.Names}}\"") }
      .returns("app-web-123\napp-web.2-123\n")

    run_command("rollout", "deploy").tap do |output|
      assert_match "--name app-web-latest ", output
      assert_match "--name app-web.2-latest ", output
      assert_match 'dash-proxy rollout deploy app-web --target="123:80,123:80"', output
    end
  end

  private
    def run_command(*command, config: :with_replicas, host: "1.1.1.1", allow_execute_error: false)
      stdouted do
        Dash::Cli::App.start([ *command, "-c", "test/fixtures/deploy_#{config}.yml", *([ "--hosts", host ] if host) ])
      rescue SSHKit::Runner::ExecuteError => e
        raise e unless allow_execute_error
      end
    end

    # The one capture a boot makes before it starts anything, in Commands::App#boot_states
    # order: slot 1's clash and running version, every running container of the role, then
    # slot 2..max's clash.
    def stub_boot_states(running:, role: :web, clashes: {})
      max = role == :web ? 2 : 3
      names = running.map { |replica, version| replica == 1 ? "app-#{role}-#{version}" : "app-#{role}.#{replica}-#{version}" }
      segments = [ clashes[1], running[1], names.join("\n"), *(2..max).map { |replica| clashes[replica] } ]

      stub_boot_state_output segments.map(&:to_s).join("\n#{SEPARATOR}\n")
    end

    def stub_boot_state_output(output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| args.join(" ").include?(SEPARATOR) }
        .returns(output)
    end

    def stub_run_capture_ids(*ids)
      stub_capture { |args| docker_run?(args) }.returns(*ids)
    end
end
