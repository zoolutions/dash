require "test_helper"

class ConfigurationRoleScaleTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      servers: {
        "web" => [ "1.1.1.1" ],
        "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "bundle exec sidekiq", "healthcheck" => false }
      },
      autoscale: { "provider" => { "upcloud" => { "username" => [ "UPCLOUD_USERNAME" ], "password" => [ "UPCLOUD_PASSWORD" ] } } }
    }
  end

  test "a role without scale is not scaled" do
    assert_not role(:payments).scaled?
    assert_nil role(:payments).scale
  end

  test "defaults: power members on the private address, five minutes to boot, min the baseline" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 3 }
    scale = role(:payments).scale

    assert role(:payments).scaled?
    assert_equal 1, scale.min
    assert_equal 3, scale.max
    assert_equal :power, scale.members
    assert scale.power?
    assert_equal "private", scale.address
    assert_equal 300, scale.boot_timeout
    assert_nil scale.template
  end

  test "create members carry their template" do
    template = { "storage" => "0123", "plan" => "CLOUDNATIVE-2xCPU-4GB", "zone" => "de-fra1", "login_user" => "deploy", "network" => "03ab" }
    @deploy[:servers]["payments"]["scale"] = { "min" => 1, "max" => 4, "members" => "create", "template" => template, "address" => "public", "boot_timeout" => 120 }
    scale = role(:payments).scale

    assert scale.create?
    assert_equal template, scale.template
    assert_equal "public", scale.address
    assert_equal 120, scale.boot_timeout
  end

  test "min below the baseline hosts is an error" do
    @deploy[:servers]["payments"]["hosts"] = [ "1.1.1.3", "1.1.1.4" ]
    @deploy[:servers]["payments"]["scale"] = { "min" => 1, "max" => 3 }

    assert_raises_message(/servers\/payments\/scale: min \(1\) cannot be less than the 2 hosts listed under hosts/) { role(:payments) }
  end

  test "min above max is an error" do
    @deploy[:servers]["payments"]["scale"] = { "min" => 3, "max" => 2 }

    assert_raises_message(/servers\/payments\/scale: min \(3\) cannot be greater than max \(2\)/) { role(:payments) }
  end

  test "max is required" do
    @deploy[:servers]["payments"]["scale"] = { "min" => 1 }

    assert_raises_message(/servers\/payments\/scale\/max: is required/) { role(:payments) }
  end

  test "members must be power or create" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "members" => "spawn" }

    assert_raises_message(/servers\/payments\/scale\/members: must be power or create, not spawn/) { role(:payments) }
  end

  test "address must be private, public or utility" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "address" => "ipv6" }

    assert_raises_message(/servers\/payments\/scale\/address: must be private, public or utility, not ipv6/) { role(:payments) }
  end

  test "create requires a template, power refuses one" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "members" => "create" }
    assert_raises_message(/servers\/payments\/scale\/template: is required with members: create/) { role(:payments) }

    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "template" => { "plan" => "x" } }
    assert_raises_message(/servers\/payments\/scale\/template: is only used with members: create/) { role(:payments) }
  end

  test "a private create address needs a network to attach" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "members" => "create", "template" => { "storage" => "0123", "plan" => "p", "zone" => "z" } }

    assert_raises_message(/servers\/payments\/scale\/template\/network: is required when address is private/) { role(:payments) }
  end

  test "the controller's keys are not accepted yet" do
    %w[ schedule warmup signal up down cooldown step hold_when ].each do |key|
      @deploy[:servers]["payments"]["scale"] = { "max" => 2, key => {} }

      assert_raises_message(/servers\/payments\/scale: #{key} belongs to the autoscaling controller, which is not part of dash yet \(zoolutions\/dash#180\)/) { role(:payments) }
    end
  end

  test "other unknown keys are rejected" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "minimum" => 1 }

    assert_raises_message(/servers\/payments\/scale: unknown key: minimum/) { role(:payments) }
  end

  test "bounds are integers" do
    @deploy[:servers]["payments"]["scale"] = { "max" => "4" }

    assert_raises_message(/servers\/payments\/scale\/max: should be an integer/) { role(:payments) }
  end

  test "a scaled role needs the autoscale provider" do
    @deploy.delete(:autoscale)
    @deploy[:servers]["payments"]["scale"] = { "max" => 2 }

    assert_raises_message(/servers\/payments\/scale: needs a provider for its members, set autoscale\/provider/) { config }
  end

  private
    def config
      Dash::Configuration.new(@deploy)
    end

    def role(name)
      config.role(name)
    end

    def assert_raises_message(pattern, &block)
      error = assert_raises(Dash::ConfigurationError, &block)
      assert_match pattern, error.message
    end
end
