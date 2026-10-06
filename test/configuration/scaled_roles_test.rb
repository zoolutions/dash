require "test_helper"

# Role#hosts of a scaled role is the baseline plus the started pool members; everything
# that runs while deploy.yml loads reads the baseline only, so loading never asks the
# provider.
class ConfigurationScaledRolesTest < ActiveSupport::TestCase
  setup do
    ENV["VERSION"] = "999"
  end

  teardown do
    ENV.delete("VERSION")
  end

  test "loading and validating a scaled configuration never asks the provider" do
    Dash::Autoscale::Pool.any_instance.expects(:members_for).never
    Dash::Autoscale::Provider::Upcloud.any_instance.expects(:members).never

    [ "deploy_with_scale", "deploy_with_scale_web" ].each do |fixture|
      config = load_fixture(fixture)
      config.to_h
      config.proxy.load_balancing?
      config.proxy.effective_loadbalancer
    end
  end

  test "hosts are the baseline plus the started members, baseline first" do
    stub_members "payments" => [ member("m1", "10.0.0.22", "started"), member("m2", "10.0.0.23", "stopped"), member("m3", "10.0.0.24", "maintenance") ]
    role = load_fixture("deploy_with_scale").role(:payments)

    assert_equal [ "1.1.1.2" ], role.baseline_hosts
    assert_equal [ "1.1.1.2", "10.0.0.22" ], role.hosts
    assert_equal [ "m1", "m2", "m3" ], role.members.map(&:id)
    assert_equal [ "m1" ], role.active_members.map(&:id)
    assert role.member_host?("10.0.0.22")
    assert_not role.member_host?("1.1.1.2")
    assert_not role.member_host?("10.0.0.23")
  end

  test "members show up in every host list that reads role hosts" do
    stub_members "payments" => [ member("m1", "10.0.0.22", "started") ]
    config = load_fixture("deploy_with_scale")

    assert_includes config.all_hosts, "10.0.0.22"
    assert_includes config.app_hosts, "10.0.0.22"
    assert_equal [ "payments" ], config.host_roles("10.0.0.22").map(&:name)
    assert_not_includes config.proxy_hosts, "10.0.0.22"
  end

  test "an unscaled role never asks the pool" do
    Dash::Autoscale::Pool.any_instance.expects(:members_for).with { |role| role.name == "payments" }.returns([])
    config = load_fixture("deploy_with_scale")

    assert_equal [ "1.1.1.1" ], config.role(:web).hosts
    assert_equal [], config.role(:web).members
    config.role(:payments).hosts
  end

  test "a member host has no env tags, a host of no role still raises" do
    stub_members "payments" => [ member("m1", "10.0.0.22", "started") ]
    role = load_fixture("deploy_with_scale").role(:payments)

    assert_equal [], role.env_tags("10.0.0.22")
    assert_equal [], role.env_tags(SSHKit::Host.new("10.0.0.22")), "on() hands SSHKit hosts, not strings"
    assert role.member_host?(SSHKit::Host.new("10.0.0.22"))
    assert_raises(KeyError) { role.env_tags("9.9.9.9") }
  end

  test "a role with only members resolves its secrets on a member" do
    stub_members "workers" => [ member("m1", "10.0.0.22", "started") ]
    deploy = base_deploy.deep_merge(servers: { "workers" => { "hosts" => [], "cmd" => "bin/jobs", "healthcheck" => false, "scale" => { "max" => 2 } } },
      allow_empty_roles: true, autoscale: exec_provider)
    config = Dash::Configuration.new(deploy)

    Dash::Configuration::Role.any_instance.expects(:secrets_io).with("1.1.1.1")
    Dash::Configuration::Role.any_instance.expects(:secrets_io).with("10.0.0.22")
    config.validate_secrets!
  end

  test "dash config lists the baseline hosts and notes the members" do
    Dash::Autoscale::Pool.any_instance.expects(:members_for).never
    config = load_fixture("deploy_with_scale").to_h

    assert_equal [ "1.1.1.2", "1.1.1.1" ], config[:hosts]
    assert_equal "1.1.1.1", config[:primary_host]
    assert_equal({ "payments" => "power members from upcloud, 1-3 hosts" }, config[:members])
  end

  test "an unscaled configuration has no members note" do
    assert_nil Dash::Configuration.new(base_deploy).to_h[:members]
  end

  test "a scaled proxied role turns the load balancer on with one baseline host" do
    proxy = load_fixture("deploy_with_scale_web").proxy

    assert proxy.load_balancing?
    assert_equal "1.1.1.1", proxy.effective_loadbalancer
  end

  test "a scaled worker role does not turn the load balancer on" do
    assert_not load_fixture("deploy_with_scale").proxy.load_balancing?
  end

  test "a non-primary scaled proxied role turns the load balancer on" do
    deploy = base_deploy.deep_merge(servers: { "api" => { "hosts" => [ "1.1.1.5" ], "proxy" => { "host" => "api.example.com" }, "scale" => { "max" => 2 } } },
      autoscale: exec_provider)

    assert Dash::Configuration.new(deploy).proxy.load_balancing?
  end

  test "loadbalancer: false is an error for a scaled proxied role" do
    deploy = base_deploy.deep_merge(servers: { "web" => { "hosts" => [ "1.1.1.1" ], "scale" => { "max" => 2 } } }, proxy: { "loadbalancer" => false }, autoscale: exec_provider)

    error = assert_raises(Dash::ConfigurationError) { Dash::Configuration.new(deploy) }
    assert_equal "servers/web/scale: a scaled role behind dash-proxy needs the load balancer, remove proxy/loadbalancer: false", error.message
  end

  test "loadbalancer: false is fine for a scaled worker role" do
    deploy = base_deploy.deep_merge(servers: { "workers" => { "hosts" => [ "1.1.1.2" ], "cmd" => "bin/jobs", "healthcheck" => false, "scale" => { "max" => 2 } } },
      proxy: { "loadbalancer" => false }, autoscale: exec_provider)

    assert_not Dash::Configuration.new(deploy).proxy.load_balancing?
  end

  test "the load balancer targets the baseline and the started members" do
    stub_members "web" => [ member("w1", "10.0.0.40", "started"), member("w2", "10.0.0.41", "stopped") ]
    config = load_fixture("deploy_with_scale_web")
    loadbalancer = Dash::Configuration::Loadbalancer.new(config: config, proxy_config: config.proxy.proxy_config, secrets: config.secrets)

    assert_equal [ "1.1.1.1", "10.0.0.40" ], loadbalancer.target_hosts
    assert loadbalancer.on_proxy_host?
  end

  test "the load balancer's host does not move with the pool" do
    stub_members "web" => [ member("w1", "10.0.0.40", "started") ]

    assert_equal "1.1.1.1", load_fixture("deploy_with_scale_web").proxy.effective_loadbalancer
  end

  test "an accessory on a scaled role runs on its baseline hosts only" do
    Dash::Autoscale::Pool.any_instance.expects(:members_for).never
    deploy = base_deploy.deep_merge(servers: { "workers" => { "hosts" => [ "1.1.1.2" ], "cmd" => "bin/jobs", "healthcheck" => false, "scale" => { "max" => 2 } } },
      accessories: { "redis" => { "image" => "redis", "role" => "workers" } }, autoscale: exec_provider)

    assert_equal [ "1.1.1.2" ], Dash::Configuration.new(deploy).accessory(:redis).hosts
  end

  test "a provider failure fails the hosts read" do
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "upcloud: GET /1.3/server answered 401")

    error = assert_raises(Dash::Autoscale::ProviderError) { load_fixture("deploy_with_scale").role(:payments).hosts }
    assert_equal "Could not read the payments pool: upcloud: GET /1.3/server answered 401", error.message
  end

  private
    def load_fixture(name, **kwargs)
      Dash::Configuration.create_from(config_file: Pathname.new(File.expand_path("../fixtures/#{name}.yml", __dir__)), **kwargs)
    end

    def stub_members(by_role)
      Dash::Autoscale::Pool.any_instance.stubs(:members_for).returns([])
      by_role.each do |role_name, members|
        Dash::Autoscale::Pool.any_instance.stubs(:members_for).with { |role| role.name == role_name }.returns(members)
      end
    end

    def member(id, host, state)
      Dash::Autoscale::Member.new(id: id, host: host, role: nil, state: state)
    end

    def exec_provider
      { "provider" => { "exec" => { "members" => "a", "start" => "b", "stop" => "c" } } }
    end

    def base_deploy
      { service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" }, servers: { "web" => [ "1.1.1.1" ] } }
    end
end
