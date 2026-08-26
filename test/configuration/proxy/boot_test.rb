require "test_helper"

class ConfigurationProxyBootTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app",
      registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      env: { "REDIS_URL" => "redis://x/y" },
      servers: [ "1.1.1.1", "1.1.1.2" ],
      volumes: [ "/local/path:/container/path" ]
    }

    @config = Dash::Configuration.new(@deploy)
    @proxy_boot_config = @config.proxy_boot
  end

  test "proxy directories" do
    assert_equal ".dash/proxy/apps-config", @proxy_boot_config.apps_directory
    assert_equal "/home/dash-proxy/.apps-config", @proxy_boot_config.apps_container_directory
    assert_equal ".dash/proxy/apps-config/app", @proxy_boot_config.app_directory
    assert_equal "/home/dash-proxy/.apps-config/app", @proxy_boot_config.app_container_directory
    assert_equal ".dash/proxy/apps-config/app/error_pages", @proxy_boot_config.error_pages_directory
    assert_equal "/home/dash-proxy/.apps-config/app/error_pages", @proxy_boot_config.error_pages_container_directory
    assert_equal ".dash/proxy/apps-config/app/tls", @proxy_boot_config.tls_directory
    assert_equal "/home/dash-proxy/.apps-config/app/tls", @proxy_boot_config.tls_container_directory
  end
end
