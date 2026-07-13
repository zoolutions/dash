require "test_helper"

class ConfigurationProxyTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "ssl with host" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with multiple hosts passed via host" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com,anotherexample.com" }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with multiple hosts passed via hosts" do
    @deploy[:proxy] = { "ssl" => true, "hosts" => [ "example.com", "anotherexample.com" ] }
    assert_equal true, config.proxy.ssl?
  end

  test "ssl with no host" do
    @deploy[:proxy] = { "ssl" => true }
    assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
  end

  test "ssl with both host and hosts" do
    @deploy[:proxy] = { "ssl" => true, host: "example.com", hosts: [ "anotherexample.com" ] }
    assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
  end

  test "ssl false" do
    @deploy[:proxy] = { "ssl" => false }
    assert_not config.proxy.ssl?
  end

  test "false not allowed" do
    @deploy[:proxy] = false
    assert_raises(Kamal::ConfigurationError, "proxy: should be a hash") do
      config.proxy
    end
  end

  test "ssl with certificate and private key from secrets" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM",
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }

      proxy = config.proxy
      assert_equal ".kamal/proxy/apps-config/app/tls/cert.pem", proxy.host_tls_cert
      assert_equal ".kamal/proxy/apps-config/app/tls/key.pem", proxy.host_tls_key
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/cert.pem", proxy.container_tls_cert
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/key.pem", proxy.container_tls_key
    end
  end

  test "deploy options with custom ssl certificates" do
    with_test_secrets("secrets" => "CERT_PEM=certificate\nKEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM",
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }

      proxy = config.proxy
      options = proxy.deploy_options
      assert_equal true, options[:tls]
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/cert.pem", options[:"tls-certificate-path"]
      assert_equal "/home/kamal-proxy/.apps-config/app/tls/key.pem", options[:"tls-private-key-path"]
    end
  end

  test "ssl with certificate and no private key" do
    with_test_secrets("secrets" => "CERT_PEM=certificate") do
      @deploy[:proxy] = {
        "ssl" => {
          "certificate_pem" => "CERT_PEM"
        },
        "host" => "example.com"
      }
      assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
    end
  end

  test "ssl with private key and no certificate" do
    with_test_secrets("secrets" => "KEY_PEM=private_key") do
      @deploy[:proxy] = {
        "ssl" => {
          "private_key_pem" => "KEY_PEM"
        },
        "host" => "example.com"
      }
      assert_raises(Kamal::ConfigurationError) { config.proxy.ssl? }
    end
  end

  test "ssl_staging, read_targets and writer affinity flags in deploy_options" do
    @deploy[:proxy] = {
      "ssl" => true, "host" => "example.com",
      "ssl_staging" => true,
      "read_targets" => [ "192.168.0.2:3000", "192.168.0.3:3000" ],
      "read_target_websockets" => true,
      "writer_affinity_timeout" => 10
    }
    options = config.proxy.deploy_options
    assert_equal true, options[:"tls-staging"]
    assert_equal [ "192.168.0.2:3000", "192.168.0.3:3000" ], options[:"read-target"]
    assert_equal true, options[:"read-target-websockets"]
    assert_equal "10s", options[:"writer-affinity-timeout"]
  end

  test "ssl_staging, read_targets and writer affinity flags absent when not configured" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com" }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-staging")
    assert_not options.key?(:"read-target")
    assert_not options.key?(:"read-target-websockets")
    assert_not options.key?(:"writer-affinity-timeout")
  end

  test "ssl_staging and read_target_websockets false emit no flags" do
    @deploy[:proxy] = { "ssl" => true, "host" => "example.com", "ssl_staging" => false, "read_target_websockets" => false }
    options = config.proxy.deploy_options
    assert_not options.key?(:"tls-staging")
    assert_not options.key?(:"read-target-websockets")
  end

  test "read_targets in deploy command args" do
    @deploy[:proxy] = { "host" => "example.com", "read_targets" => [ "192.168.0.2:3000" ] }
    args = config.proxy.deploy_command_args(target: "abc123:80")
    assert_includes args.join(" "), "--read-target=\"192.168.0.2:3000\""
  end

  test "invalid types for ssl_staging, read_targets and writer affinity keys" do
    {
      "ssl_staging" => "yes",
      "read_targets" => "192.168.0.2:3000",
      "read_target_websockets" => 1,
      "writer_affinity_timeout" => "10"
    }.each do |key, value|
      @deploy[:proxy] = { "host" => "example.com", key => value }
      assert_raises(Kamal::ConfigurationError, "expected #{key}=#{value.inspect} to be rejected") { config.proxy }
    end
  end

  private
    def config
      Kamal::Configuration.new(@deploy)
    end
end
