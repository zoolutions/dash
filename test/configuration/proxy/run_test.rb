require "test_helper"

class ConfigurationProxyRunTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"
  end

  test "run objects with identical config are equal" do
    deploy = base_deploy.deep_merge(proxy: { "run" => { "log_max_size" => "50m" } })
    config = Dash::Configuration.new(deploy)

    run_a = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })
    run_b = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })

    assert_equal run_a, run_b
    assert_equal run_a.hash, run_b.hash
    assert_equal 1, [ run_a, run_b ].uniq.size
  end

  test "run objects with different config are not equal" do
    deploy = base_deploy.deep_merge(proxy: { "run" => { "log_max_size" => "50m" } })
    config = Dash::Configuration.new(deploy)

    run_a = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })
    run_b = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "100m" })

    assert_not_equal run_a, run_b
    assert_equal 2, [ run_a, run_b ].uniq.size
  end

  test "no conflict when global proxy run config is inherited by role proxy" do
    deploy = base_deploy.deep_merge(
      servers: {
        "web" => { "hosts" => [ "1.1.1.1" ] },
        "worker" => {
          "hosts" => [ "1.1.1.1" ],
          "cmd" => "bin/jobs",
          "proxy" => {
            "hosts" => [ "worker.example.com" ],
            "app_port" => 8080
          }
        }
      },
      proxy: {
        "hosts" => [ "example.com" ],
        "run" => {
          "log_max_size" => "",
          "options" => { "log-driver" => "journald" }
        }
      }
    )

    # Should not raise Dash::ConfigurationError
    config = Dash::Configuration.new(deploy)
    assert config
  end

  test "config_digest is stable for identical configs" do
    config = Dash::Configuration.new(base_deploy)

    run_a = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })
    run_b = Dash::Configuration::Proxy::Run.new(config, run_config: { "log_max_size" => "50m" })

    assert_equal run_a.config_digest, run_b.config_digest
  end

  test "config_digest changes when version, ports or options change" do
    config = Dash::Configuration.new(base_deploy)
    base = Dash::Configuration::Proxy::Run.new(config, run_config: {})

    assert_not_equal base.config_digest,
      Dash::Configuration::Proxy::Run.new(config, run_config: { "version" => "v9.9.9" }).config_digest
    assert_not_equal base.config_digest,
      Dash::Configuration::Proxy::Run.new(config, run_config: { "http_port" => 8080 }).config_digest
    assert_not_equal base.config_digest,
      Dash::Configuration::Proxy::Run.new(config, run_config: { "options" => { "cpus" => 2 } }).config_digest
  end

  test "digest is deterministic and input-sensitive" do
    assert_equal Dash::Configuration::Proxy::Run.digest("a", "b"), Dash::Configuration::Proxy::Run.digest("a", "b")
    assert_not_equal Dash::Configuration::Proxy::Run.digest("a"), Dash::Configuration::Proxy::Run.digest("b")
  end

  test "run command re-verifies restored targets" do
    config = Dash::Configuration.new(base_deploy)
    run = Dash::Configuration::Proxy::Run.new(config, run_config: {})

    assert_equal "dash-proxy run --recheck-targets-on-restore", run.run_command
  end

  test "port_holder defaults to false with kamal network and published ports" do
    config = Dash::Configuration.new(base_deploy)
    run = Dash::Configuration::Proxy::Run.new(config, run_config: {})

    assert_not run.port_holder?
    assert_equal [ "--network", "dash" ], run.network_args
    assert_match "--publish 80:80", run.docker_options_args.join(" ")
    assert_no_match(/--reuse-port/, run.run_command)
  end

  test "port_holder moves ports to the holder and joins its namespace" do
    config = Dash::Configuration.new(base_deploy)
    run = Dash::Configuration::Proxy::Run.new(config, run_config: { "port_holder" => true })

    assert run.port_holder?
    assert_equal "dash-proxy-net", run.holder_container_name
    assert_equal [ "--network", "container:dash-proxy-net" ], run.network_args
    assert_no_match(/--publish/, run.docker_options_args.join(" "))
    assert_match "--publish 80:80 --publish 443:443", run.holder_docker_args.join(" ")
    assert_match "--reuse-port", run.run_command
  end

  test "config_digest changes when port_holder flips" do
    config = Dash::Configuration.new(base_deploy)

    assert_not_equal \
      Dash::Configuration::Proxy::Run.new(config, run_config: {}).config_digest,
      Dash::Configuration::Proxy::Run.new(config, run_config: { "port_holder" => true }).config_digest
  end

  private
    def base_deploy
      {
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ]
      }
    end
end
