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

  test "unknown providers are rejected" do
    @deploy[:autoscale] = { "provider" => { "hetzner" => {} } }

    assert_raises_message(%r{autoscale/provider: unknown key: hetzner}) { config }
  end

  test "the controller's keys are not accepted yet" do
    %w[ interval redis postgres prometheus ].each do |key|
      @deploy[:autoscale] = { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } }, key => {} }

      assert_raises_message(%r{autoscale: #{key} belongs to the autoscaling controller, which is not part of dash yet \(zoolutions/dash#180\)}) { config }
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
