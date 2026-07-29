require "test_helper"

class ConfigurationBootTest < ActiveSupport::TestCase
  APP_HOSTS = %w[ 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 ]

  test "no boot config" do
    config = config_with_boot(nil)

    assert_nil config.boot.limit_for(APP_HOSTS)
    assert_nil config.boot.wait
    assert_nil config.boot.parallel_roles
  end

  test "specific limit group strategy" do
    config = config_with_boot("limit" => 3, "wait" => 2)

    assert_equal 3, config.boot.limit_for(APP_HOSTS)
    assert_equal 2, config.boot.wait
  end

  test "an integer limit ignores the host set" do
    config = config_with_boot("limit" => 3)

    assert_equal 3, config.boot.limit_for(APP_HOSTS)
    assert_equal 3, config.boot.limit_for(%w[ 1.1.1.1 ])
    assert_equal 3, config.boot.limit_for([])
  end

  test "percentage-based group strategy" do
    config = config_with_boot("limit" => "50%", "wait" => 2)

    assert_equal 2, config.boot.limit_for(APP_HOSTS)
    assert_equal 2, config.boot.wait
  end

  test "percentage-based group strategy limit is at least 1" do
    config = config_with_boot("limit" => "1%", "wait" => 2)

    assert_equal 1, config.boot.limit_for(APP_HOSTS)
    assert_equal 2, config.boot.wait
  end

  test "a percentage counts the hosts it will slice, not every host in the file" do
    # Accessory hosts are never booted by host_boot_groups, so they were never a legitimate
    # denominator — and --roles/--hosts narrow the set further at run time.
    config = config_with_boot({ "limit" => "50%" }, %w[ 1.1.1.5 1.1.1.6 1.1.1.7 1.1.1.8 ])

    assert_equal 2, config.boot.limit_for(APP_HOSTS)
    assert_equal 1, config.boot.limit_for(%w[ 1.1.1.1 1.1.1.2 ])
  end

  test "parallel_roles" do
    config = config_with_boot("parallel_roles" => true)

    assert_equal true, config.boot.parallel_roles
  end

  test "no runner options without a limit" do
    assert_equal({}, config_with_boot(nil).boot.runner_options_for(APP_HOSTS))
    assert_equal({}, config_with_boot("wait" => 5).boot.runner_options_for(APP_HOSTS))
  end

  test "limit of one runs in sequence to avoid a trailing wait" do
    assert_equal({ in: :sequence, wait: 0 }, config_with_boot("limit" => 1).boot.runner_options_for(APP_HOSTS))
    assert_equal({ in: :sequence, wait: 5 }, config_with_boot("limit" => 1, "wait" => 5).boot.runner_options_for(APP_HOSTS))
  end

  test "limit above one runs in groups" do
    assert_equal({ in: :groups, limit: 3, wait: 0 }, config_with_boot("limit" => 3).boot.runner_options_for(APP_HOSTS))
    assert_equal({ in: :groups, limit: 3, wait: 2 }, config_with_boot("limit" => 3, "wait" => 2).boot.runner_options_for(APP_HOSTS))
  end

  test "a percentage that resolves to one runs in sequence" do
    boot = config_with_boot("limit" => "50%").boot

    assert_equal({ in: :groups, limit: 2, wait: 0 }, boot.runner_options_for(APP_HOSTS))
    assert_equal({ in: :sequence, wait: 0 }, boot.runner_options_for(%w[ 1.1.1.1 1.1.1.2 ]))
  end

  test "role-scoped boot reports its own context on a validation error" do
    config = config_with_boot(nil)

    error = assert_raises(Kamal::ConfigurationError) do
      Kamal::Configuration::Boot.new \
        config: config, boot_config: { "limit" => [ 1 ] }, context: "servers/workers/boot"
    end

    assert_match "servers/workers/boot/limit", error.message
  end

  private
    # accessory_hosts stays positional: a keyword here would swallow the bare `boot` hash
    # every other caller passes.
    def config_with_boot(boot, accessory_hosts = [])
      deploy = {
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, builder: { "arch" => "amd64" },
        servers: { "web" => [ "1.1.1.1", "1.1.1.2" ], "workers" => [ "1.1.1.3", "1.1.1.4" ] },
        boot: boot
      }.compact

      if accessory_hosts.any?
        deploy[:accessories] = accessory_hosts.each_with_index.to_h { |host, index|
          [ "db#{index}", { "image" => "mysql:8", "host" => host } ]
        }
      end

      Kamal::Configuration.new(deploy)
    end
end
