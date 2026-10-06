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

  test "an UpCloud create template names its storage, plan and zone" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "members" => "create", "address" => "public", "template" => { "plan" => "p" } }

    assert_raises_message(/servers\/payments\/scale\/template: storage, zone are required to create an UpCloud server/) { config }
  end

  test "an exec create template is the script's business" do
    @deploy[:autoscale] = { "provider" => { "exec" => { "members" => "a", "start" => "b", "stop" => "c", "create" => "d" } } }
    @deploy[:servers]["payments"]["scale"] = { "max" => 2, "members" => "create", "address" => "public", "template" => { "plan" => "p" } }

    assert config.role(:payments).scale.create?
  end

  test "the reactive rules' keys are not accepted yet" do
    %w[ signal up down hold_when ].each do |key|
      @deploy[:servers]["payments"]["scale"] = { "max" => 2, key => {} }

      assert_raises_message(/servers\/payments\/scale: #{key} belongs to the reactive autoscaling rules, which are not part of dash yet \(zoolutions\/dash#180, Phase 3\)/) { role(:payments) }
    end
  end

  test "controller defaults: no schedule, warmup is boot_timeout, cooldowns 60/600, step one host's worth" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 1, "max" => 3 }
    @deploy[:servers]["payments"]["scale"] = { "max" => 4, "boot_timeout" => 240 }
    scale = role(:payments).scale

    assert_empty scale.schedule
    assert_equal 240, scale.warmup
    assert_equal 60, scale.cooldown_up
    assert_equal 600, scale.cooldown_down
    assert_equal 3, scale.step
  end

  test "container bounds are scale bounds times replicas bounds" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 2, "max" => 3 }
    @deploy[:servers]["payments"]["scale"] = { "min" => 1, "max" => 4 }
    scale = role(:payments).scale

    assert_equal 2, scale.min_count
    assert_equal 12, scale.max_count
  end

  test "schedule windows, warmup, cooldown and step" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 1, "max" => 3 }
    @deploy[:servers]["payments"]["scale"] = { "min" => 1, "max" => 4,
      "schedule" => [ { "cron" => "0 22 14,28-31 * *", "for" => "30h", "min" => 10 }, { "cron" => "0 9 * * 1-5", "for" => 3600, "min" => 4 } ],
      "warmup" => 120, "cooldown" => { "up" => 30, "down" => 900 }, "step" => 2 }
    scale = role(:payments).scale

    assert_equal [ { cron: "0 22 14,28-31 * *", for: 108_000, min: 10 }, { cron: "0 9 * * 1-5", for: 3600, min: 4 } ], scale.schedule.map(&:to_h)
    assert_equal 120, scale.warmup
    assert_equal 30, scale.cooldown_up
    assert_equal 900, scale.cooldown_down
    assert_equal 2, scale.step
  end

  test "a window needs a valid cron, a duration of 1 second to 7 days and a min it can run" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 1, "max" => 3 }

    { { "cron" => "0 0 L * *", "for" => "1h", "min" => 2 } => %r{scale/schedule/0/cron: day-of-month: L is not supported},
      { "cron" => "0 0 * *", "for" => "1h", "min" => 2 } => %r{scale/schedule/0/cron: "0 0 \* \*" has 4 fields},
      { "for" => "1h", "min" => 2 } => %r{scale/schedule/0/cron: is required},
      { "cron" => "0 0 * * *", "min" => 2 } => %r{scale/schedule/0/for: is required},
      { "cron" => "0 0 * * *", "for" => "8d", "min" => 2 } => %r{scale/schedule/0/for: must be 1 second to 7 days, not 8d},
      { "cron" => "0 0 * * *", "for" => 0, "min" => 2 } => %r{scale/schedule/0/for: must be 1 second to 7 days, not 0},
      { "cron" => "0 0 * * *", "for" => "2w", "min" => 2 } => %r{scale/schedule/0/for: "2w" should be seconds},
      { "cron" => "0 0 * * *", "for" => "1h" } => %r{scale/schedule/0/min: is required},
      { "cron" => "0 0 * * *", "for" => "1h", "min" => 13 } => %r{scale/schedule/0/min: must be 1 to 12 \(scale max 4 × replicas max 3\), not 13},
      { "cron" => "0 0 * * *", "for" => "1h", "min" => "4" } => %r{scale/schedule/0/min: must be 1 to 12},
      { "cron" => "0 0 * * *", "for" => "1h", "min" => 2, "max" => 4 } => %r{scale/schedule/0: unknown key: max} }.each do |window, pattern|
      @deploy[:servers]["payments"]["scale"] = { "max" => 4, "schedule" => [ window ] }

      assert_raises_message(pattern) { role(:payments) }
    end
  end

  test "a window min the role's hosts cannot split is an error" do
    @deploy[:servers]["payments"]["replicas"] = 3
    @deploy[:servers]["payments"]["scale"] = { "max" => 4, "schedule" => [ { "cron" => "0 0 * * *", "for" => "1h", "min" => 4 } ] }

    assert_raises_message(%r{scale/schedule/0/min: 4 containers cannot be split over the role's hosts \(replicas min 3, max 3 per host, 1 to 4 hosts\)}) { role(:payments) }
  end

  test "a window min below the role's min is allowed, and changes nothing" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 2, "max" => 3 }
    @deploy[:servers]["payments"]["scale"] = { "max" => 4, "schedule" => [ { "cron" => "0 0 * * *", "for" => "1h", "min" => 1 } ] }

    assert_equal 1, role(:payments).scale.schedule.first.min
  end

  test "the schedule is a list" do
    @deploy[:servers]["payments"]["scale"] = { "max" => 4, "schedule" => { "cron" => "0 0 * * *" } }

    assert_raises_message(%r{servers/payments/scale/schedule: should be an array}) { role(:payments) }
  end

  test "warmup, cooldowns and step bounds" do
    { { "warmup" => -1 } => %r{scale/warmup: must be at least 0},
      { "cooldown" => { "down" => -5 } } => %r{scale/cooldown/down: must be at least 0},
      { "cooldown" => { "up" => -5 } } => %r{scale/cooldown/up: must be at least 0},
      { "cooldown" => { "sideways" => 5 } } => %r{scale/cooldown: unknown key: sideways},
      { "step" => 0 } => %r{scale/step: must be at least 1} }.each do |keys, pattern|
      @deploy[:servers]["payments"]["scale"] = { "max" => 4 }.merge(keys)

      assert_raises_message(pattern) { role(:payments) }
    end
  end

  test "whether a container count can be split over the role's hosts" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 2, "max" => 3 }
    @deploy[:servers]["payments"]["scale"] = { "min" => 1, "max" => 3 }
    scale = role(:payments).scale

    assert_equal [ 2, 3, 4, 5, 6, 7, 8, 9 ], (0..12).select { |count| scale.splittable?(count) }
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
