require "test_helper"

class ConfigurationBootTest < ActiveSupport::TestCase
  test "no boot config" do
    config = config_with_boot(nil)

    assert_nil config.boot.limit
    assert_nil config.boot.wait
    assert_nil config.boot.parallel_roles
  end

  test "specific limit group strategy" do
    config = config_with_boot("limit" => 3, "wait" => 2)

    assert_equal 3, config.boot.limit
    assert_equal 2, config.boot.wait
  end

  test "percentage-based group strategy" do
    config = config_with_boot("limit" => "50%", "wait" => 2)

    assert_equal 2, config.boot.limit
    assert_equal 2, config.boot.wait
  end

  test "percentage-based group strategy limit is at least 1" do
    config = config_with_boot("limit" => "1%", "wait" => 2)

    assert_equal 1, config.boot.limit
    assert_equal 2, config.boot.wait
  end

  test "parallel_roles" do
    config = config_with_boot("parallel_roles" => true)

    assert_equal true, config.boot.parallel_roles
  end

  test "no runner options without a limit" do
    assert_equal({}, config_with_boot(nil).boot.runner_options)
    assert_equal({}, config_with_boot("wait" => 5).boot.runner_options)
  end

  test "limit of one runs in sequence to avoid a trailing wait" do
    assert_equal({ in: :sequence, wait: 0 }, config_with_boot("limit" => 1).boot.runner_options)
    assert_equal({ in: :sequence, wait: 5 }, config_with_boot("limit" => 1, "wait" => 5).boot.runner_options)
  end

  test "limit above one runs in groups" do
    assert_equal({ in: :groups, limit: 3, wait: 0 }, config_with_boot("limit" => 3).boot.runner_options)
    assert_equal({ in: :groups, limit: 3, wait: 2 }, config_with_boot("limit" => 3, "wait" => 2).boot.runner_options)
  end

  test "role-scoped boot counts percentages against the role's own hosts" do
    config = config_with_boot(nil)

    boot = Kamal::Configuration::Boot.new \
      config: config, boot_config: { "limit" => "50%" }, host_count: 2, context: "servers/workers/boot"

    assert_equal 1, boot.limit
    assert_equal({ in: :sequence, wait: 0 }, boot.runner_options)
  end

  test "role-scoped boot reports its own context on a validation error" do
    config = config_with_boot(nil)

    error = assert_raises(Kamal::ConfigurationError) do
      Kamal::Configuration::Boot.new \
        config: config, boot_config: { "limit" => [ 1 ] }, host_count: 2, context: "servers/workers/boot"
    end

    assert_match "servers/workers/boot/limit", error.message
  end

  private
    def config_with_boot(boot)
      deploy = {
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, builder: { "arch" => "amd64" },
        servers: { "web" => [ "1.1.1.1", "1.1.1.2" ], "workers" => [ "1.1.1.3", "1.1.1.4" ] },
        boot: boot
      }.compact

      Kamal::Configuration.new(deploy)
    end
end
