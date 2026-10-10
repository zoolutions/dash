require "test_helper"

class ConfigurationAutoscaleTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      servers: { "web" => [ "1.1.1.1" ] }
    }
  end

  test "no autoscale key, no provider" do
    assert_not config.autoscale.configured?
    assert_nil config.autoscale.provider_name
  end

  test "upcloud reads its credentials from secrets, only when asked" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => [ "UPCLOUD_USERNAME" ], "password" => [ "UPCLOUD_PASSWORD" ] } } }
    autoscale = config.autoscale

    assert autoscale.configured?
    assert_equal "upcloud", autoscale.provider_name

    Dash::Secrets.any_instance.stubs(:[]).with("UPCLOUD_USERNAME").returns("api-user")
    Dash::Secrets.any_instance.stubs(:[]).with("UPCLOUD_PASSWORD").returns("api-secret")

    assert_equal "api-user", autoscale.upcloud_username
    assert_equal "api-secret", autoscale.upcloud_password
  end

  test "constructing the configuration never reads the provider secrets" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => [ "UPCLOUD_USERNAME" ], "password" => [ "UPCLOUD_PASSWORD" ] } } }
    Dash::Secrets.any_instance.expects(:[]).never

    config
  end

  test "a plain string credential is used as written" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "api-user", "password" => [ "UPCLOUD_PASSWORD" ] } } }

    assert_equal "api-user", config.autoscale.upcloud_username
  end

  test "a credential that resolves to nothing fails naming the secret" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => [ "UPCLOUD_USERNAME" ], "password" => [ "UPCLOUD_PASSWORD" ] } } }
    Dash::Secrets.any_instance.stubs(:[]).returns("")

    error = assert_raises(Dash::ConfigurationError) { config.autoscale.upcloud_password }
    assert_match %r{autoscale/provider/upcloud/password: secret 'UPCLOUD_PASSWORD' resolved to an empty value}, error.message
  end

  test "exec names its scripts" do
    @deploy[:autoscale] = { "provider" => { "exec" => { "members" => "bin/pool-members", "start" => "bin/pool-start", "stop" => "bin/pool-stop" } } }

    assert_equal "exec", config.autoscale.provider_name
    assert_equal "bin/pool-members", config.autoscale.exec_script(:members)
    assert_nil config.autoscale.exec_script(:create)
  end

  test "exec needs members, start and stop" do
    @deploy[:autoscale] = { "provider" => { "exec" => { "members" => "bin/pool-members" } } }

    assert_raises_message(%r{autoscale/provider/exec/start: is required}) { config }
  end

  test "exactly one provider" do
    @deploy[:autoscale] = { "provider" => {
      "upcloud" => { "username" => "u", "password" => "p" },
      "exec" => { "members" => "a", "start" => "b", "stop" => "c" }
    } }
    assert_raises_message(%r{autoscale/provider: set exactly one of upcloud or exec}) { config }

    @deploy[:autoscale] = { "provider" => {} }
    assert_raises_message(%r{autoscale/provider: set exactly one of upcloud or exec}) { config }
  end

  test "a provider is required" do
    @deploy[:autoscale] = {}

    assert_raises_message(%r{autoscale/provider: is required}) { config }
  end

  test "upcloud needs both credentials" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u" } } }

    assert_raises_message(%r{autoscale/provider/upcloud/password: is required}) { config }
  end

  test "a secret reference needs a name" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => [ "" ], "password" => "p" } } }

    assert_raises_message(%r{autoscale/provider/upcloud/username: is required}) { config }
  end

  test "unknown providers are rejected" do
    @deploy[:autoscale] = { "provider" => { "hetzner" => {} } }

    assert_raises_message(%r{autoscale/provider: unknown key: hetzner}) { config }
  end

  test "the reactive rules' keys are not accepted yet" do
    %w[ redis postgres prometheus ].each do |key|
      @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } }, key => {} }

      assert_raises_message(%r{autoscale: #{key} belongs to the reactive autoscaling rules, which are not part of dash yet \(zoolutions/dash#180, Phase 3\)}) { config }
    end
  end

  test "controller defaults: a tick every 10 seconds, 60 seconds for the lock, UTC" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } } }
    autoscale = config.autoscale

    assert_equal 10, autoscale.interval
    assert_equal 60, autoscale.lock_wait_timeout
    assert_equal "UTC", autoscale.timezone
    assert_equal ActiveSupport::TimeZone["UTC"], autoscale.time_zone
  end

  test "interval, lock_wait_timeout and timezone" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } },
      "interval" => 30, "lock_wait_timeout" => 0, "timezone" => "Europe/Stockholm" }
    autoscale = config.autoscale

    assert_equal 30, autoscale.interval
    assert_equal 0, autoscale.lock_wait_timeout
    assert_equal "Europe/Stockholm", autoscale.time_zone.tzinfo.name
  end

  test "controller key bounds and types" do
    { { "interval" => 4 } => %r{autoscale/interval: must be at least 5 seconds, not 4},
      { "interval" => "10" } => %r{autoscale/interval: should be an integer},
      { "lock_wait_timeout" => -1 } => %r{autoscale/lock_wait_timeout: must be at least 0, not -1},
      { "timezone" => "Mars/Olympus" } => %r{autoscale/timezone: unknown time zone Mars/Olympus},
      { "timezone" => 1 } => %r{autoscale/timezone: should be a string} }.each do |keys, pattern|
      @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } } }.merge(keys)

      assert_raises_message(pattern) { config }
    end
  end

  test "no controller host by default" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } } }

    assert_nil config.autoscale.controller
  end

  test "controller names the ops host that keeps the state" do
    @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } }, "controller" => "10.0.0.50" }

    assert_equal "10.0.0.50", config.autoscale.controller
  end

  test "controller must be a host name" do
    { "" => %r{autoscale/controller: should be a host name}, " " => %r{autoscale/controller: should be a host name},
      [ "10.0.0.50" ] => %r{autoscale/controller: should be a host name}, " 10.0.0.50" => %r{autoscale/controller: should be a host name}, 1 => %r{autoscale/controller: should be a host name} }.each do |value, pattern|
      @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } }, "controller" => value }

      assert_raises_message(pattern) { config }
    end
  end

  private
    def config
      Dash::Configuration.new(@deploy)
    end

    def assert_raises_message(pattern, &block)
      error = assert_raises(Dash::ConfigurationError, &block)
      assert_match pattern, error.message
    end
end
