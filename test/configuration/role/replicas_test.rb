require "test_helper"

class ConfigurationRoleReplicasTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      servers: {
        "web" => { "hosts" => [ "1.1.1.1", "1.1.1.2" ] },
        "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "bundle exec sidekiq", "healthcheck" => false }
      }
    }
  end

  test "defaults to one replica, which is today's behaviour" do
    replicas = role(:payments).replicas

    assert_equal 1, replicas.min
    assert_equal 1, replicas.max
    assert_not replicas.scalable?
    assert_equal [ 1 ], role(:payments).replica_numbers
  end

  test "an integer is shorthand for min and max" do
    @deploy[:servers]["web"]["replicas"] = 2

    assert_equal [ 2, 2 ], [ role(:web).replicas.min, role(:web).replicas.max ]
    assert role(:web).replicas.scalable?
    assert_equal [ 1, 2 ], role(:web).replica_numbers
  end

  test "a hash sets min and max" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 1, "max" => 4 }

    assert_equal [ 1, 4 ], [ role(:payments).replicas.min, role(:payments).replicas.max ]
    assert_equal [ 1, 2, 3, 4 ], role(:payments).replica_numbers
  end

  test "a hash may set only max" do
    @deploy[:servers]["payments"]["replicas"] = { "max" => 3 }

    assert_equal [ 1, 3 ], [ role(:payments).replicas.min, role(:payments).replicas.max ]
  end

  test "a hash with only min raises max to match" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 3 }

    assert_equal [ 3, 3 ], [ role(:payments).replicas.min, role(:payments).replicas.max ]
  end

  test "clamp keeps a runtime count within the bounds" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 2, "max" => 4 }
    replicas = role(:payments).replicas

    assert_equal 2, replicas.clamp(0)
    assert_equal 3, replicas.clamp(3)
    assert_equal 4, replicas.clamp(9)
  end

  test "describes itself for the deploy banner" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 1, "max" => 4 }
    @deploy[:servers]["web"]["replicas"] = 2

    assert_equal "× 1–4 replicas", role(:payments).replicas.to_s
    assert_equal "× 2 replicas", role(:web).replicas.to_s
  end

  test "min must be at least 1" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 0, "max" => 2 }

    assert_config_error "servers/payments/replicas: min must be at least 1"
  end

  test "min may not exceed max" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => 3, "max" => 2 }

    assert_config_error "servers/payments/replicas: min (3) cannot be greater than max (2)"
  end

  test "replicas must be integers" do
    @deploy[:servers]["payments"]["replicas"] = { "min" => "two" }

    assert_config_error "servers/payments/replicas/min: should be an integer"
  end

  test "replicas must be an integer or a hash" do
    @deploy[:servers]["payments"]["replicas"] = "lots"

    assert_config_error "servers/payments/replicas: should be an integer, or a hash with min and max"
  end

  test "replicas reject unknown keys" do
    @deploy[:servers]["payments"]["replicas"] = { "desired" => 2 }

    assert_config_error "servers/payments/replicas: unknown key: desired"
  end

  %w[ publish p name hostname ].each do |option|
    test "more than one replica cannot set the #{option} option" do
      @deploy[:servers]["payments"]["replicas"] = { "max" => 2 }
      @deploy[:servers]["payments"]["options"] = { option => "x" }

      assert_config_error "servers/payments/replicas: max > 1 cannot be combined with options/#{option}, every replica on a host would claim it"
    end
  end

  test "one replica may still publish a port" do
    @deploy[:servers]["payments"]["options"] = { "publish" => "8080:8080" }

    assert_nothing_raised { config }
  end

  test "more than one replica cannot sleep through dash-proxy yet" do
    @deploy[:servers]["web"]["replicas"] = 2
    @deploy[:proxy] = { "sleep" => { "after" => 300 }, "run" => { "docker_socket" => "/var/run/docker.sock" } }

    assert_config_error "servers/web/replicas: max > 1 cannot be combined with proxy/sleep"
  end

  test "host volumes warn when replicas share them" do
    @deploy[:servers]["payments"]["replicas"] = { "max" => 2 }
    @deploy[:volumes] = [ "/data:/data" ]

    _, err = capture_io { config }
    assert_match "servers/payments/replicas: every replica on a host shares the volume /data:/data", err
  end

  test "a role volume option warns when replicas share it" do
    @deploy[:servers]["payments"]["replicas"] = { "max" => 2 }
    @deploy[:servers]["payments"]["options"] = { "volume" => "/data:/data" }

    _, err = capture_io { config }
    assert_match "every replica on a host shares the volume /data:/data", err
  end

  test "volumes do not warn for a single replica" do
    @deploy[:volumes] = [ "/data:/data" ]

    _, err = capture_io { config }
    assert_no_match(/shares the volume/, err)
  end

  test "drain signal and wait" do
    @deploy[:servers]["payments"]["drain"] = { "signal" => "TSTP", "wait" => 120 }

    assert_equal "TSTP", role(:payments).drain_signal
    assert_equal 120, role(:payments).drain_wait
  end

  test "no drain by default" do
    assert_nil role(:payments).drain_signal
    assert_equal 0, role(:payments).drain_wait
  end

  test "drain accepts a SIG prefix and a signal number" do
    @deploy[:servers]["payments"]["drain"] = { "signal" => "SIGUSR1" }
    assert_equal "SIGUSR1", role(:payments).drain_signal

    @deploy[:servers]["payments"]["drain"] = { "signal" => 20 }
    assert_equal "20", role(:payments).drain_signal
  end

  test "drain signal must be one docker accepts" do
    @deploy[:servers]["payments"]["drain"] = { "signal" => "QUIETLY" }

    assert_config_error "servers/payments/drain/signal: QUIETLY is not a signal docker can send"
  end

  test "drain signal numbers must be in the Linux range" do
    @deploy[:servers]["payments"]["drain"] = { "signal" => 999 }

    assert_config_error "servers/payments/drain/signal: 999 is not a signal docker can send"
  end

  test "drain wait cannot be negative" do
    @deploy[:servers]["payments"]["drain"] = { "wait" => -1 }

    assert_config_error "servers/payments/drain/wait: must be 0 or more seconds"
  end

  test "volumes-from warns when replicas share it" do
    @deploy[:servers]["payments"]["replicas"] = { "max" => 2 }
    @deploy[:servers]["payments"]["options"] = { "volumes-from" => "data" }

    _, err = capture_io { config }
    assert_match "every replica on a host shares the volume data", err
  end

  test "drain on a proxied role is refused because the proxy drains it" do
    @deploy[:servers]["web"]["drain"] = { "signal" => "TSTP" }

    assert_config_error "servers/web/drain: a role behind dash-proxy is drained by the proxy, remove drain"
  end

  test "slot 1 keeps today's container names" do
    assert_equal "app-web-999", role(:web).replica_name(1, "999")
    assert_equal "app-web-999", role(:web).container_name("999")
    assert_equal "app-web", role(:web).replica_prefix(1)

    with_destination = Dash::Configuration.new(@deploy, destination: "production")
    assert_equal "app-web-production-999", with_destination.role(:web).replica_name(1, "999")
    assert_equal "app-web-production-999", with_destination.role(:web).container_name("999")
  end

  test "slot n puts the slot into the role segment" do
    assert_equal "app-web.2", role(:web).replica_prefix(2)
    assert_equal "app-web.2-999", role(:web).replica_name(2, "999")

    with_destination = Dash::Configuration.new(@deploy, destination: "production")
    assert_equal "app-web.3-production-999", with_destination.role(:web).replica_name(3, "999")
  end

  test "reads the slot back out of a container name" do
    web = role(:web)

    assert_equal 1, web.replica_from_name("app-web-999")
    assert_equal 2, web.replica_from_name("app-web.2-999")
    assert_equal 12, web.replica_from_name("app-web.12-abc_replaced_1234")
    assert_nil web.replica_from_name("other-web-999")

    production = Dash::Configuration.new(@deploy, destination: "production").role(:web)
    assert_equal 1, production.replica_from_name("app-web-production-999")
    assert_equal 3, production.replica_from_name("app-web.3-production-999")
    assert_nil production.replica_from_name("app-web.3-staging-999")
  end

  test "reads the version back out of a container name" do
    production = Dash::Configuration.new(@deploy, destination: "production").role(:web)

    assert_equal "999", production.version_from_name("app-web-production-999")
    assert_equal "abc_replaced_12", production.version_from_name("app-web.2-production-abc_replaced_12")
    assert_nil production.version_from_name("app-other-production-999")
  end

  private
    def config
      Dash::Configuration.new(@deploy)
    end

    def role(name)
      config.role(name)
    end

    def assert_config_error(message)
      error = assert_raises(Dash::ConfigurationError) { config }
      assert_match message, error.message
    end
end
