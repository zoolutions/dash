require_relative "cli_test_case"

class CliScaleTest < CliTestCase
  setup do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123")
    stub_readiness_wait "no-healthcheck:running"
    stub_readiness_confirm "no-healthcheck:running"
    stub_run_capture
  end

  test "set adds a replica to the host with the fewest, in its lowest free slot" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]

    run_command("set", "payments", "3").tap do |output|
      assert_match /docker run --detach --restart unless-stopped --name app-payments.2-123 .*--env DASH_REPLICA="2"/, output
      assert_equal 1, output.scan("docker run").size, output
      assert_match "Added app-payments.2-123 on 1.1.1.2", output
      assert_match "payments now runs 3 containers", output
    end
  end

  test "set boots the new replica at the version the host runs, not the latest image" do
    stub_running "1.1.1.2" => [ "app-payments-abc" ], "1.1.1.3" => [ "app-payments-abc" ]

    run_command("set", "payments", "3").tap do |output|
      assert_match "--name app-payments.2-abc ", output
      assert_match "dhh/app:abc bundle exec sidekiq -q payments", output
    end
  end

  test "set waits for a new worker replica to be ready" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]

    captures = recorded_captures { run_command("set", "payments", "3") }

    assert captures.any? { |capture| capture.include?(Dash::Commands::Base::READINESS_PROGRESS_PREFIX) && capture.include?("name=^app-payments\\.2-123$") }, captures.inspect
  end

  test "set adds a web replica to the proxy pool with every running replica" do
    stub_running "1.1.1.1" => [ "app-web-123" ]

    run_command("set", "web", "2", config: :with_replicas_range).tap do |output|
      assert_match "--name app-web.2-123 ", output
      assert_match 'dash-proxy deploy app-web --target="123:80,123:80"', output
    end
  end

  test "set removes the highest slot from the fullest host" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123" ], "1.1.1.3" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]

    run_command("set", "payments", "4").tap do |output|
      assert_match "docker container ls --all --filter 'name=^app-payments\\.3-123$' --quiet | xargs docker stop -t 45", output
      assert_no_match(/'name=\^app-payments\\\.2-123\$' --quiet \| xargs docker stop/, output)
      assert_match "Removed app-payments.3-123 on 1.1.1.3", output
    end
  end

  test "set drains a worker replica with its signal before stopping it" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123" ], "1.1.1.3" => [ "app-payments-123" ]
    Dash::Cli::Scale::ReplicaLeave.any_instance.expects(:sleep).with(5)

    run_command("set", "payments", "2").tap do |output|
      signal = output.index("docker container ls --all --filter 'name=^app-payments\\.2-123$' --quiet | xargs docker kill --signal=TSTP")
      stop = output.index("docker container ls --all --filter 'name=^app-payments\\.2-123$' --quiet | xargs docker stop -t 45")

      assert signal, output
      assert stop, output
      assert signal < stop, output
    end
  end

  test "set takes a web replica out of the proxy pool before stopping it" do
    stub_running "1.1.1.1" => [ "app-web-123", "app-web.2-456", "app-web.3-123" ]
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("'name=^app-web-123$'") }.returns("aaaaaaaaaaaa")

    run_command("set", "web", "1", config: :with_replicas_range).tap do |output|
      deploy = output.index('dash-proxy deploy app-web --target="aaaaaaaaaaaa:80"')
      stop = output.index("'name=^app-web\\.3-123$' --quiet | xargs docker stop")

      assert deploy, output
      assert stop, output
      assert deploy < stop, output
      assert_match "'name=^app-web\\.2-456$' --quiet | xargs docker stop", output
      assert_no_match(/docker kill/, output)
    end
  end

  test "set aborts rather than guess when a host's containers cannot be listed" do
    listing = ->(args) { args.join(" ").include?("--format \"{{.Names}}\"") }
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| listing.(args) && args.last != { raise_on_non_zero_exit: false } }
      .raises(SSHKit::Command::Failed.new("Cannot connect to the Docker daemon"))
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| listing.(args) && args.last == { raise_on_non_zero_exit: false } }
      .returns("")

    assert_raises(SSHKit::Runner::ExecuteError) { run_command("set", "payments", "3") }
  end

  test "set refuses a count outside the role's bounds" do
    error = assert_raises(ArgumentError) { run_command("set", "payments", "7") }
    assert_equal "payments runs 2 to 6 containers on its 2 hosts (replicas min 1, max 3 per host), not 7", error.message

    assert_raises(ArgumentError) { run_command("set", "payments", "1") }
  end

  test "set reads the count as a decimal, so a leading zero is not octal" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]

    assert_match "payments now runs 3 containers", run_command("set", "payments", "03")
    assert_raises(ArgumentError) { run_command("set", "payments", "0x3") }
  end

  test "set refuses an unknown role" do
    error = assert_raises(ArgumentError) { run_command("set", "nope", "2") }
    assert_match "No role named nope", error.message
  end

  test "set does nothing at the current count" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]

    run_command("set", "payments", "2").tap do |output|
      assert_match "payments already runs 2 containers", output
      assert_no_match(/docker run/, output)
    end
  end

  test "set takes the deploy lock" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]

    assert_match "Acquiring the deploy lock", run_command("set", "payments", "3")
  end

  test "set runs the scale-out hooks with the resulting count" do
    stub_running "1.1.1.2" => [ "app-payments-123" ], "1.1.1.3" => [ "app-payments-123" ]
    Dash::Cli::Scale.any_instance.stubs(:run_hook)
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("pre-scale-out", role: "payments", hosts: "1.1.1.2", replicas: "3")
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("post-scale-out", role: "payments", hosts: "1.1.1.2", replicas: "3")
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("pre-scale-in", anything).never

    run_command("set", "payments", "3")
  end

  test "set runs the scale-in hooks with the resulting count" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123" ], "1.1.1.3" => [ "app-payments-123", "app-payments.2-123" ]
    Dash::Cli::Scale.any_instance.stubs(:run_hook)
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("pre-scale-in", role: "payments", hosts: "1.1.1.2,1.1.1.3", replicas: "2")
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("post-scale-in", role: "payments", hosts: "1.1.1.2,1.1.1.3", replicas: "2")

    run_command("set", "payments", "2")
  end

  test "the scale hooks see DASH_REPLICAS" do
    assert_equal "3", Dash::Tags.new(replicas: "3").env["DASH_REPLICAS"]
  end

  test "status lists every replica per host" do
    stub_status "1.1.1.2" => "app-payments-123\tUp 2 hours\napp-payments.2-123\tUp 5 minutes (healthy)\n", "1.1.1.3" => "app-payments-123\tUp 2 hours\n"

    run_command("status", "payments").tap do |output|
      assert_match "payments: 3 containers (replicas min 1, max 3 per host)", output
      assert_match /1\.1\.1\.2\s+1\s+123\s+Up 2 hours/, output
      assert_match /1\.1\.1\.2\s+2\s+123\s+Up 5 minutes \(healthy\)/, output
      assert_match /1\.1\.1\.3\s+1\s+123\s+Up 2 hours/, output
    end
  end

  test "status --json prints the same shape as a document" do
    stub_status "1.1.1.2" => "app-payments-123\tUp 2 hours\napp-payments.2-123\tUp 5 minutes\n", "1.1.1.3" => ""

    json = JSON.parse(run_command("status", "payments", "--json")[/\{.*\}/m])

    assert_equal [ "payments" ], json["roles"].map { |role| role["role"] }
    payments = json["roles"].first
    assert_equal [ 1, 3, 2 ], payments.values_at("min", "max", "total")
    assert_equal [ { "replica" => 1, "version" => "123", "status" => "Up 2 hours" }, { "replica" => 2, "version" => "123", "status" => "Up 5 minutes" } ], payments["hosts"]["1.1.1.2"]
    assert_equal [], payments["hosts"]["1.1.1.3"]
  end

  private
    def run_command(*command, config: :with_replicas)
      stdouted { Dash::Cli::Scale.start([ *command, "-c", "test/fixtures/deploy_#{config}.yml" ]) }
    end

    # What each host says is running for the role: one `docker ps` of container names.
    def stub_running(names_by_host)
      names_by_host.each do |host, names|
        SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
          .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?("--format \"{{.Names}}\"") }
          .returns(names.join("\n") + "\n")
      end
    end

    def stub_status(output_by_host)
      output_by_host.each do |host, output|
        SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
          .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?("{{.Names}}\\t{{.Status}}") }
          .returns(output)
      end
    end
end
