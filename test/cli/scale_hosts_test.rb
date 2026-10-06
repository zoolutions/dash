require_relative "cli_test_case"

# `dash scale set` on a role with `scale:` - containers fill the hosts the role has, then
# pool members join; members leave before the baseline gives a container up.
class CliScaleHostsTest < CliTestCase
  # A provider whose members change state as dash asks: start powers on, stop powers off.
  class FakeProvider < Dash::Autoscale::Provider::Base
    attr_reader :calls, :members_list

    def initialize(members)
      @members_list = members
      @calls = []
    end

    def name = "fake"

    def members(labels:, address:)
      @members_list.select { |member| member.role == labels["dash.role"] }.map(&:dup)
    end

    def start(member)
      @calls << [ :start, member.id ]
      find(member).state = "started"
    end

    def stop(member, timeout:)
      @calls << [ :stop, member.id, timeout ]
      find(member).state = "stopped"
    end

    def create(labels:, template:, address:)
      @calls << [ :create, labels["dash.role"] ]
      Dash::Autoscale::Member.new(id: "new1", host: "10.0.0.30", role: labels["dash.role"], state: "started", labels: labels).tap { |member| @members_list << member }
    end

    def destroy(member)
      @calls << [ :destroy, member.id ]
      @members_list.reject! { |candidate| candidate.id == member.id }
    end

    def state(member)
      find(member).state
    end

    private
      def find(member)
        @members_list.find { |candidate| candidate.id == member.id }
      end
  end

  setup do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123")
    stub_readiness_wait "no-healthcheck:running"
    stub_readiness_confirm "no-healthcheck:running"
    stub_run_capture

    @provider = FakeProvider.new([
      member("m1", "10.0.0.22", "payments", "stopped"),
      member("m2", "10.0.0.23", "payments", "stopped"),
      member("w1", "10.0.0.40", "web", "stopped")
    ])
    Dash::Autoscale::Provider.stubs(:for).returns(@provider)
    @narrowed = []
  end

  test "fills the baseline host to its max before any member is powered on" do
    stub_running "1.1.1.2" => [ "app-payments-123" ]

    run_command("set", "payments", "3").tap do |output|
      assert_equal 2, output.scan("docker run").size, output
      assert_match "payments now runs 3 containers on 1 host", output
    end
    assert_empty @provider.calls
  end

  test "powers a stopped member on, then boots the running version on it, narrowed to it" do
    stub_running "1.1.1.2" => [ "app-payments-abc", "app-payments.2-abc", "app-payments.3-abc" ], "10.0.0.22" => [ "app-payments-abc" ]
    record_narrowed_invokes

    run_command("set", "payments", "4").tap do |output|
      assert_match "Powering on m1 (10.0.0.22) for payments", output
      assert_match "Joined m1 (10.0.0.22) to payments", output
      assert_match "payments now runs 4 containers on 2 hosts", output
    end

    assert_equal [ [ :start, "m1" ] ], @provider.calls
    assert_equal [
      [ "dash:cli:registry:login", [ "10.0.0.22" ], [ "payments" ], { skip_local: true } ],
      [ "dash:cli:app:stale_containers", [ "10.0.0.22" ], [ "payments" ], { stop: true } ],
      [ "dash:cli:app:boot", [ "10.0.0.22" ], [ "payments" ], { version: "abc" } ]
    ], @narrowed
  end

  test "a joined member is filled like the others" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ], "10.0.0.22" => [ "app-payments-123" ]
    record_narrowed_invokes

    run_command("set", "payments", "6").tap do |output|
      assert_match "Added app-payments.2-123 on 10.0.0.22", output
      assert_match "Added app-payments.3-123 on 10.0.0.22", output
    end
  end

  test "the scale-out hooks name the member" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ], "10.0.0.22" => [ "app-payments-123" ]
    record_narrowed_invokes
    Dash::Cli::Scale.any_instance.stubs(:run_hook)
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("pre-scale-out", role: "payments", hosts: "10.0.0.22", replicas: "4")
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("post-scale-out", role: "payments", hosts: "10.0.0.22", replicas: "4")

    run_command("set", "payments", "4")
  end

  test "a join runs the real sub-commands on the member only" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ], "10.0.0.22" => [ "app-payments-123" ]

    run_command("set", "payments", "4").tap do |output|
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 10\.0\.0\.22/, output
      assert_match /docker run --detach --restart unless-stopped --name app-payments-123 .*--env KAMAL_HOST="10\.0\.0\.22"/, output
      assert_operator output.index("docker login"), :<, output.index("docker run"), output
      assert_no_match(/docker login .* on 1\.1\.1\.2/, output)
      assert_no_match(/docker pull .* on 1\.1\.1\.2/, output)
    end
  end

  test "a web member gets its proxy, then joins the load balancer with every target" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_running "1.1.1.1" => [ "app-web-123" ], "10.0.0.40" => [ "app-web-123" ]
    stub_loadbalancer_owner
    record_narrowed_invokes

    run_command("set", "web", "2", config: :with_scale_web).tap do |output|
      assert_match 'dash-proxy deploy app --target="1.1.1.1:80,10.0.0.40:80"', output
    end

    assert_equal [ "dash:cli:registry:login", "dash:cli:app:stale_containers", "dash:cli:proxy:boot", "dash:cli:app:boot" ], @narrowed.map(&:first)
    assert_equal({ skip_loadbalancer: true }, @narrowed[2].last, "the member's proxy boot must not touch the shared load balancer")
  end

  test "a leaving member stays a load balancer target while another proxied role runs on it" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    deploy = YAML.load_file("test/fixtures/deploy_with_scale_web.yml")
    deploy["servers"]["api"] = { "hosts" => [ "10.0.0.40" ], "proxy" => { "host" => "api.example.com" } }
    File.write("test/fixtures/deploy_tmp_shared_member.yml", deploy.to_yaml)
    @provider.members_list.find { |member| member.id == "w1" }.state = "started"
    stub_running "1.1.1.1" => [ "app-web-123" ], "10.0.0.40" => [ "app-web-123" ]
    stub_loadbalancer_owner

    run_command("set", "web", "1", config: :tmp_shared_member).tap do |output|
      assert_match 'dash-proxy deploy app --target="10.0.0.40:80,1.1.1.1:80" ', output
    end
  ensure
    FileUtils.rm_f "test/fixtures/deploy_tmp_shared_member.yml"
  end

  test "a web member leaves the load balancer before its containers stop and it powers off" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    @provider.members_list.find { |member| member.id == "w1" }.state = "started"
    stub_running "1.1.1.1" => [ "app-web-123" ], "10.0.0.40" => [ "app-web-123" ]
    stub_loadbalancer_owner

    run_command("set", "web", "1", config: :with_scale_web).tap do |output|
      deploy = output.index('dash-proxy deploy app --target="1.1.1.1:80"')
      stop = output.index("xargs docker stop on 10.0.0.40") || output.index("docker stop")

      assert deploy, output
      assert stop, output
      assert deploy < stop, output
      assert_match "Removed w1 (10.0.0.40) from web", output
    end

    assert_equal [ [ :stop, "w1", 60 ] ], @provider.calls
  end

  test "a worker member is drained, stopped and powered off before the baseline sheds a slot" do
    @provider.members_list.find { |member| member.id == "m1" }.state = "started"
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123" ], "10.0.0.22" => [ "app-payments-123" ]
    Dash::Cli::Scale::ReplicaLeave.any_instance.expects(:sleep).with(5)

    run_command("set", "payments", "2").tap do |output|
      signal = output.index("xargs docker kill --signal=TSTP on 10.0.0.22")
      assert signal, output
      assert_match "Removed m1 (10.0.0.22) from payments", output
      assert_no_match(/Removed app-payments.2-123 on 1\.1\.1\.2/, output)
    end

    assert_equal [ [ :stop, "m1", 60 ] ], @provider.calls
  end

  test "a failed boot powers the member off again" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]
    Dash::Cli::Scale.any_instance.stubs(:invoke_narrowed)
    Dash::Cli::Scale.any_instance.stubs(:invoke_narrowed).with("dash:cli:app:boot", anything, anything).raises(Dash::Cli::BootError, "unhealthy")

    error = assert_raises(Dash::Cli::BootError) { run_command("set", "payments", "4") }
    assert_equal "unhealthy", error.message
    assert_equal [ [ :start, "m1" ], [ :stop, "m1", 60 ] ], @provider.calls
  end

  test "--keep-on-failure leaves the member on" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]
    Dash::Cli::Scale.any_instance.stubs(:invoke_narrowed)
    Dash::Cli::Scale.any_instance.stubs(:invoke_narrowed).with("dash:cli:app:boot", anything, anything).raises(Dash::Cli::BootError, "unhealthy")

    assert_raises(Dash::Cli::BootError) { run_command("set", "payments", "4", "--keep-on-failure") }
    assert_equal [ [ :start, "m1" ] ], @provider.calls
  end

  test "a member that never reaches started is powered off again" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]
    record_narrowed_invokes
    @provider.define_singleton_method(:wait_until) do |member, state:, timeout:, interval: 5|
      state == "started" ? raise(Dash::Autoscale::ProviderError, "fake: #{member.id} is maintenance, not started, after #{timeout}s") : state
    end

    error = assert_raises(Dash::Autoscale::ProviderError) { run_command("set", "payments", "4") }
    assert_match "m1 is maintenance, not started", error.message
    assert_equal [ [ :start, "m1" ], [ :stop, "m1", 60 ] ], @provider.calls
    assert_empty @narrowed
  end

  test "a created member that never reaches started is destroyed" do
    deploy_with_create
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]
    @provider.define_singleton_method(:wait_until) do |member, state:, timeout:, interval: 5|
      state == "started" ? raise(Dash::Autoscale::ProviderError, "fake: not started") : state
    end

    assert_raises(Dash::Autoscale::ProviderError) { run_command("set", "payments", "4", config: :tmp_scale_create) }
    assert_equal [ [ :create, "payments" ], [ :stop, "new1", 60 ], [ :destroy, "new1" ] ], @provider.calls
  ensure
    FileUtils.rm_f "test/fixtures/deploy_tmp_scale_create.yml"
  end

  test "a join that fails after the load balancer took the member takes it out again before powering it off" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_running "1.1.1.1" => [ "app-web-123" ], "10.0.0.40" => [ "app-web-123" ]
    stub_loadbalancer_owner
    record_narrowed_invokes
    Dash::Cli::Scale.any_instance.stubs(:run_hook)
    Dash::Cli::Scale.any_instance.stubs(:run_hook).with("post-scale-out", anything).raises(Dash::Cli::HookError, "post-scale-out failed")

    error = nil
    output = stdouted do
      Dash::Cli::Scale.start([ "set", "web", "2", "-c", "test/fixtures/deploy_with_scale_web.yml" ])
    rescue Dash::Cli::HookError => e
      error = e
    end

    assert_equal "post-scale-out failed", error&.message
    assert_equal [ [ :start, "w1" ], [ :stop, "w1", 60 ] ], @provider.calls

    joined = output.index('dash-proxy deploy app --target="1.1.1.1:80,10.0.0.40:80"')
    left = output.index('dash-proxy deploy app --target="1.1.1.1:80" ', joined.to_i + 1)
    assert joined, output
    assert left, "the rollback must redeploy the load balancer without the member: #{output}"
  end

  test "an unreachable web member is replaced with no command reaching it: out of the load balancer, then powered off" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    @provider.members_list.find { |member| member.id == "w1" }.state = "started"
    stub_loadbalancer_owner

    output = stdouted { replace_unreachable(:with_scale_web, "web", "w1", count: 1) }

    assert_match 'dash-proxy deploy app --target="1.1.1.1:80" ', output
    assert_match "Removing w1 (10.0.0.40) from web, unreachable...", output
    assert_match "Removed w1 (10.0.0.40) from web", output
    assert_no_match(/on 10\.0\.0\.40/, output)
    assert_equal [ [ :stop, "w1", 60 ] ], @provider.calls
    assert_not_includes DASH.run_directory_ensured_on, "10.0.0.40", "a member powered on again later gets its run directory ensured"
  end

  test "an unreachable worker member is powered off without a drain, under the deploy lock, with the scale-in hooks" do
    @provider.members_list.find { |member| member.id == "m1" }.state = "started"
    Dash::Cli::Scale.any_instance.stubs(:run_hook)
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("pre-scale-in", role: "payments", hosts: "10.0.0.22", replicas: "3")
    Dash::Cli::Scale.any_instance.expects(:run_hook).with("post-scale-in", role: "payments", hosts: "10.0.0.22", replicas: "3")
    Dash::Cli::Scale::ReplicaLeave.any_instance.expects(:run).never

    output = stdouted { replace_unreachable(:with_scale, "payments", "m1", count: 3) }

    assert_operator output.index("Acquiring the deploy lock"), :<, output.index("Removing m1 (10.0.0.22) from payments, unreachable")
    assert_operator output.index("Removed m1 (10.0.0.22) from payments"), :<, output.index("Releasing the deploy lock")
    assert_no_match(/on 10\.0\.0\.22/, output)
    assert_equal [ [ :stop, "m1", 60 ] ], @provider.calls
  end

  test "an unreachable created member is destroyed" do
    deploy_with_create
    @provider.members_list << member("new1", "10.0.0.30", "payments", "started")

    stdouted { replace_unreachable(:tmp_scale_create, "payments", "new1", count: 3) }

    assert_equal [ [ :stop, "new1", 60 ], [ :destroy, "new1" ] ], @provider.calls
  ensure
    FileUtils.rm_f "test/fixtures/deploy_tmp_scale_create.yml"
  end

  test "a baseline host is never replaced" do
    error = assert_raises(ArgumentError) do
      stdouted { replace_unreachable(:with_scale, "payments", nil, count: 3, member: member("b", "1.1.1.2", "payments", "started")) }
    end
    assert_match "1.1.1.2 is a baseline host of payments, dash scale never stops it", error.message
    assert_empty @provider.calls
  end

  test "a stopped member is not stopped again before it is destroyed" do
    @provider.members_list << member("gone", "10.0.0.50", "payments", "stopped")
    Dash::Cli::Scale::PowerOff.new(payments_role, @provider.members_list.last, @provider).run(destroy: true)

    assert_equal [ [ :destroy, "gone" ] ], @provider.calls
  end

  test "a member that never answers SSH fails the join after boot_timeout" do
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]
    Dash::Cli::Scale.any_instance.stubs(:on_hosts).raises(SSHKit::Runner::ExecuteError.new(Errno::ECONNREFUSED.new))
    Dash::Cli::Scale::Join.any_instance.stubs(:monotonic_now).returns(0, 0, 301)

    error = assert_raises(Dash::Cli::BootError) { run_command("set", "payments", "4") }
    assert_match "10.0.0.22 did not answer SSH within payments scale/boot_timeout (300s)", error.message
    assert_equal [ [ :start, "m1" ], [ :stop, "m1", 60 ] ], @provider.calls
  end

  test "a create role creates a member from its template and destroys it when it leaves" do
    deploy_with_create
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ], "10.0.0.30" => [ "app-payments-123" ]
    record_narrowed_invokes

    run_command("set", "payments", "4", config: :tmp_scale_create)
    assert_equal [ [ :create, "payments" ] ], @provider.calls
    assert_equal "dash:cli:server:bootstrap", @narrowed.first.first

    @provider.calls.clear
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ], "10.0.0.30" => [ "app-payments-123" ]
    Dash::Cli::Scale::ReplicaLeave.any_instance.stubs(:sleep)
    run_command("set", "payments", "3", config: :tmp_scale_create)
    assert_equal [ [ :stop, "new1", 60 ], [ :destroy, "new1" ] ], @provider.calls
  ensure
    FileUtils.rm_f "test/fixtures/deploy_tmp_scale_create.yml"
  end

  test "an orphan worker member leaves without waiting out a drain it has nothing for" do
    @provider.members_list.find { |member| member.id == "m1" }.state = "started"
    stub_running "1.1.1.2" => [ "app-payments-123" ], "10.0.0.22" => []
    Dash::Cli::Scale::ReplicaLeave.any_instance.expects(:sleep).never

    run_command("set", "payments", "1")
    assert_equal [ [ :stop, "m1", 60 ] ], @provider.calls
  end

  test "refuses a count beyond scale max times replicas max, naming both bounds" do
    error = assert_raises(ArgumentError) { run_command("set", "payments", "10") }

    assert_equal "payments runs 1 to 9 containers on 1 to 3 hosts (replicas min 1, max 3 per host), not 10", error.message
  end

  test "refuses to join more members than are stopped" do
    @provider.members_list.select! { |member| member.id == "m1" }
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123", "app-payments.3-123" ]

    error = assert_raises(ArgumentError) { run_command("set", "payments", "9") }
    assert_match "payments needs 2 more hosts but has 1 stopped member to power on", error.message
    assert_empty @provider.calls
  end

  test "refuses to join without a running version" do
    stub_running "1.1.1.2" => []

    error = assert_raises(Dash::Cli::BootError) { run_command("set", "payments", "4") }
    assert_equal "No running version of payments to join a member at; run dash deploy first", error.message
    assert_empty @provider.calls
  end

  test "a pool that could not be read refuses scale set, even with only baseline hosts named" do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(name: "fake").tap { |provider| provider.stubs(:members).raises(Dash::Autoscale::ProviderError, "down") })
    Dash::Autoscale::Pool.any_instance.stubs(:warn)
    stub_running "1.1.1.2" => [ "app-payments-123", "app-payments.2-123" ]

    error = assert_raises(ArgumentError) { run_command("set", "payments", "1", "--hosts", "1.1.1.2") }
    assert_match "the payments pool could not be read", error.message
  end

  test "with members from --hosts a member is never powered on or off" do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(members: nil).tap { |provider| provider.stubs(:members).raises(Dash::Autoscale::ProviderError, "down") })
    Dash::Autoscale::Pool.any_instance.stubs(:warn)
    stub_running "1.1.1.2" => [ "app-payments-123" ], "10.0.0.22" => [ "app-payments-123" ]

    error = assert_raises(ArgumentError) { run_command("set", "payments", "1", "--hosts", "1.1.1.2,10.0.0.22") }
    assert_match "the payments pool could not be read", error.message
  end

  test "status lists the members, and flags a started one running nothing as an orphan" do
    @provider.members_list.find { |member| member.id == "m1" }.state = "started"
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("{{.Names}}\\t{{.Status}}") }.returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| SSHKit::Backend.current.host.to_s == "1.1.1.2" && args.join(" ").include?("{{.Names}}\\t{{.Status}}") }.returns("app-payments-123\tUp 2 hours\n")

    run_command("status", "payments").tap do |output|
      assert_match "payments: 1 container (replicas min 1, max 3 per host on 1 to 3 hosts)", output
      assert_match /member m1\s+10\.0\.0\.22\s+started - orphan: started, but runs nothing of the role/, output
      assert_match /member m2\s+10\.0\.0\.23\s+stopped/, output
    end
  end

  test "an unscaled role scales as before" do
    stub_running "1.1.1.1" => [ "app-web-123" ]

    run_command("set", "web", "1").tap do |output|
      assert_match "web already runs 1 containers", output
    end
  end

  private
    def run_command(*command, config: :with_scale)
      stdouted { Dash::Cli::Scale.start([ *command, "-c", "test/fixtures/deploy_#{config}.yml" ]) }
    end

    def replace_unreachable(config, role_name, member_id, count:, member: nil)
      cli = Dash::Cli::Scale.new([], { "config_file" => "test/fixtures/deploy_#{config}.yml" }, invocations: { Dash::Cli::Scale => [ "set" ] })
      role = DASH.config.role(role_name)
      member ||= role.members.find { |candidate| candidate.id == member_id }

      cli.replace_unreachable(role, member, count: count)
    end

    def payments_role
      Dash::Configuration.create_from(config_file: Pathname.new(File.expand_path("test/fixtures/deploy_with_scale.yml"))).role(:payments)
    end

    def member(id, host, role, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: role, state: state, labels: { "dash.role" => role })
    end

    # Records each narrowed sub-command with the scope DASH had while it ran.
    def record_narrowed_invokes
      narrowed = @narrowed
      Dash::Cli::Scale.any_instance.stubs(:invoke_narrowed).with do |command, _cli_class, **options|
        narrowed << [ command, DASH.specific_hosts, DASH.specific_roles.map(&:name), options ]
        true
      end
    end

    def stub_running(names_by_host)
      names_by_host.each do |host, names|
        SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
          .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?("--format \"{{.Names}}\"") }
          .returns(names.join("\n") + "\n")
      end
    end

    # Nobody else owns the service on the load balancer.
    def stub_loadbalancer_owner
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| args.first == :cat && args.join(" ").include?("loadbalancer/services") }.returns("")
    end

    def deploy_with_create
      deploy = YAML.load_file("test/fixtures/deploy_with_scale.yml")
      deploy["servers"]["payments"]["scale"] = { "min" => 1, "max" => 3, "members" => "create", "address" => "public",
        "template" => { "storage" => "tmpl", "plan" => "p", "zone" => "z" } }
      File.write("test/fixtures/deploy_tmp_scale_create.yml", deploy.to_yaml)
    end
end
