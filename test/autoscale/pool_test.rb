require "test_helper"

class AutoscalePoolTest < ActiveSupport::TestCase
  setup do
    ENV["VERSION"] = "999"
    @provider = mock("provider")
    Dash::Autoscale::Provider.stubs(:for).returns(@provider)
  end

  teardown do
    ENV.delete("VERSION")
  end

  test "asks the provider once per role, with the role's labels and address" do
    @provider.expects(:members).once
      .with(labels: { "dash.service" => "app", "dash.destination" => "-", "dash.role" => "payments" }, address: "private")
      .returns([ member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "stopped") ])
    pool = config.pool

    assert_equal [ "m1", "m2" ], pool.members_for(role).map(&:id)
    assert_equal [ "m1" ], pool.active_for(role).map(&:id)
    pool.members_for(role)
  end

  test "the destination label is the destination" do
    config = load_fixture
    config.stubs(:destination).returns("staging")

    assert_equal "staging", config.pool.labels_for(config.role(:payments))["dash.destination"]
  end

  test "refresh! asks again" do
    @provider.expects(:members).twice.returns([ member("m1", "10.0.0.22", "stopped") ], [ member("m1", "10.0.0.22", "started") ])
    pool = config.pool

    assert_equal [], pool.active_for(role).map(&:id)
    assert_equal [ "m1" ], pool.refresh!.active_for(role).map(&:id)
  end

  test "concurrent first reads ask the provider once" do
    @provider.expects(:members).once.returns([])
    pool = config.pool

    4.times.map { Thread.new { pool.members_for(role) } }.each(&:join)
  end

  test "a provider failure without --hosts fails naming the provider and the role" do
    @provider.stubs(:members).raises(Dash::Autoscale::ProviderError, "upcloud: GET /1.3/server failed (SocketError: down)")

    error = assert_raises(Dash::Autoscale::ProviderError) { config.pool.members_for(role) }
    assert_equal "Could not read the payments pool from upcloud: upcloud: GET /1.3/server failed (SocketError: down)", error.message
  end

  test "with --hosts the named non-baseline hosts are taken as unverified members, with one warning" do
    @provider.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")
    config = load_fixture(explicit_hosts: [ "10.0.0.22", "1.1.1.2", "10.0.0.*" ])
    pool = config.pool

    pool.expects(:warn).once.with("Could not read the payments pool from upcloud (down); taking 10.0.0.22 from --hosts as started members, unverified")
    members = pool.members_for(config.role(:payments))
    pool.refresh!.members_for(config.role(:payments))

    assert_equal [ [ "10.0.0.22", "started", false ] ], members.map { |member| [ member.host, member.state, member.verified ] }
  end

  test "with --hosts and two scaled roles in scope, --roles has to pick one" do
    @provider.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")
    deploy = YAML.load_file(fixture_path).deep_merge("servers" => { "web" => { "hosts" => [ "1.1.1.1" ], "scale" => { "max" => 2 } } })

    config = Dash::Configuration.new(deploy.symbolize_keys, explicit_hosts: [ "10.0.0.22" ])
    error = assert_raises(Dash::Autoscale::ProviderError) { config.pool.members_for(config.role(:payments)) }
    assert_match(/--hosts could mean members of payments or web; name one with --roles/, error.message)

    config = Dash::Configuration.new(deploy.symbolize_keys, explicit_hosts: [ "10.0.0.22" ], explicit_roles: [ "web" ])
    config.pool.stubs(:warn)
    assert_equal [], config.pool.members_for(config.role(:payments))
    assert_equal [ "10.0.0.22" ], config.pool.members_for(config.role(:web)).map(&:host)
  end

  test "--hosts naming a member reaches Commander through the configuration" do
    @provider.stubs(:members).returns([ member("m1", "10.0.0.22", "started") ])
    commander = Dash::Commander.new
    commander.configure config_file: fixture_path, explicit_hosts: [ "10.0.0.22" ]
    commander.specific_hosts = [ "10.0.0.22" ]

    assert_equal [ "10.0.0.22" ], commander.hosts
    assert_equal [ "payments" ], commander.roles.map(&:name)
  end

  private
    def config
      @config ||= load_fixture
    end

    def role
      config.role(:payments)
    end

    def load_fixture(**kwargs)
      Dash::Configuration.create_from(config_file: fixture_path, **kwargs)
    end

    def fixture_path
      Pathname.new(File.expand_path("../fixtures/deploy_with_scale.yml", __dir__))
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: "payments", state: state)
    end
end
