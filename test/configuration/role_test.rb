require "test_helper"

class ConfigurationRoleTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      servers: [ "1.1.1.1", "1.1.1.2" ],
      builder: { "arch" => "amd64" },
      env: { "REDIS_URL" => "redis://x/y" }
    }

    @deploy_with_roles = @deploy.dup.merge({
      servers: {
        "web" => [ "1.1.1.1", "1.1.1.2" ],
        "workers" => {
          "hosts" => [ "1.1.1.3", "1.1.1.4" ],
          "cmd" => "bin/jobs",
          # Readiness is not what most of these tests are about, and without the opt-out
          # every Configuration.new here warns to stderr. Tests that do exercise the
          # ungated path delete this key.
          "healthcheck" => false,
          "env" => {
            "REDIS_URL" => "redis://a/b",
            "WEB_CONCURRENCY" => "4"
          }
        }
      }
    })
  end

  test "hosts" do
    assert_equal [ "1.1.1.1", "1.1.1.2" ], config.role(:web).hosts
    assert_equal [ "1.1.1.3", "1.1.1.4" ], config_with_roles.role(:workers).hosts
  end

  test "missing env tag is ignored" do
    @deploy_with_roles[:servers]["workers"]["hosts"] = [ { "1.1.1.3" => [ "job" ] } ]

    role = Kamal::Configuration.new(@deploy_with_roles).role(:workers)
    assert_equal "redis://a/b", role.env("1.1.1.3").clear["REDIS_URL"]
  end

  test "cmd" do
    assert_nil config.role(:web).cmd
    assert_equal "bin/jobs", config_with_roles.role(:workers).cmd
  end

  test "label args" do
    assert_equal [ "--label", "service=\"app\"", "--label", "role=\"workers\"", "--label", "destination" ], config_with_roles.role(:workers).label_args
  end

  test "special label args for web" do
    assert_equal [ "--label", "service=\"app\"", "--label", "role=\"web\"", "--label", "destination" ], config.role(:web).label_args
  end

  test "custom labels" do
    @deploy[:labels] = { "my.custom.label" => "50" }
    assert_equal "50", config.role(:web).labels["my.custom.label"]
  end

  test "custom labels via role specialization" do
    @deploy_with_roles[:labels] = { "my.custom.label" => "50" }
    @deploy_with_roles[:servers]["workers"]["labels"] = { "my.custom.label" => "70" }
    assert_equal "70", Kamal::Configuration.new(@deploy_with_roles).role(:workers).labels["my.custom.label"]
  end

  test "default proxy label on non-web role" do
    config = Kamal::Configuration.new(@deploy_with_roles.tap { |c|
      c[:servers]["beta"] = { "proxy" => true, "hosts" => [ "1.1.1.5" ] }
    })

    assert_equal [ "--label", "service=\"app\"", "--label", "role=\"beta\"", "--label", "destination" ], config.role(:beta).label_args
  end

  test "env overwritten by role" do
    assert_equal "redis://a/b", config_with_roles.role(:workers).env("1.1.1.3").clear["REDIS_URL"]

    assert_equal \
      [ "--env", "REDIS_URL=\"redis://a/b\"", "--env", "WEB_CONCURRENCY=\"4\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
      config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

    assert_equal \
      "\n",
      config_with_roles.role(:workers).secrets_io("1.1.1.3").read
  end

  test "container name" do
    ENV["VERSION"] = "12345"

    assert_equal "app-workers-12345", config_with_roles.role(:workers).container_name
    assert_equal "app-web-12345", config_with_roles.role(:web).container_name
  ensure
    ENV.delete("VERSION")
  end

  test "env args" do
    assert_equal \
      [ "--env", "REDIS_URL=\"redis://a/b\"", "--env", "WEB_CONCURRENCY=\"4\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
      config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

    assert_equal \
      "\n",
      config_with_roles.role(:workers).secrets_io("1.1.1.3").read
  end

  test "env secret overwritten by role" do
    with_test_secrets("secrets" => "REDIS_PASSWORD=secret456\nDB_PASSWORD=secret&\"123") do
      @deploy_with_roles[:env] = {
        "clear" => {
          "REDIS_URL" => "redis://a/b"
        },
        "secret" => [
          "REDIS_PASSWORD"
        ]
      }

      @deploy_with_roles[:servers]["workers"]["env"] = {
        "clear" => {
          "REDIS_URL" => "redis://a/b",
          "WEB_CONCURRENCY" => "4"
        },
        "secret" => [
          "DB_PASSWORD"
        ]
      }

      assert_equal \
        [ "--env", "REDIS_URL=\"redis://a/b\"", "--env", "WEB_CONCURRENCY=\"4\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
        config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

      assert_equal \
        "REDIS_PASSWORD=secret456\nDB_PASSWORD=secret&\"123\n",
        config_with_roles.role(:workers).secrets_io("1.1.1.3").read
    end
  end

  test "env secrets only in role" do
    with_test_secrets("secrets" => "DB_PASSWORD=secret123") do
      @deploy_with_roles[:servers]["workers"]["env"] = {
        "clear" => {
          "REDIS_URL" => "redis://a/b",
          "WEB_CONCURRENCY" => "4"
        },
        "secret" => [
          "DB_PASSWORD"
        ]
      }

      assert_equal \
        [ "--env", "REDIS_URL=\"redis://a/b\"", "--env", "WEB_CONCURRENCY=\"4\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
        config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

      assert_equal \
        "DB_PASSWORD=secret123\n",
        config_with_roles.role(:workers).secrets_io("1.1.1.3").read
    end
  end

  test "env secrets only at top level" do
    with_test_secrets("secrets" => "REDIS_PASSWORD=secret456") do
      @deploy_with_roles[:env] = {
        "clear" => {
          "REDIS_URL" => "redis://a/b"
        },
        "secret" => [
          "REDIS_PASSWORD"
        ]
      }

      assert_equal \
        [ "--env", "REDIS_URL=\"redis://a/b\"", "--env", "WEB_CONCURRENCY=\"4\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
        config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

      assert_equal \
        "REDIS_PASSWORD=secret456\n",
        config_with_roles.role(:workers).secrets_io("1.1.1.3").read
    end
  end

  test "env overwritten by role with secrets" do
    with_test_secrets("secrets" => "REDIS_PASSWORD=secret456") do
      @deploy_with_roles[:env] = {
        "clear" => {
          "REDIS_URL" => "redis://a/b"
        },
        "secret" => [
          "REDIS_PASSWORD"
        ]
      }

      @deploy_with_roles[:servers]["workers"]["env"] = {
        "clear" => {
          "REDIS_URL" => "redis://c/d"
        }
      }

      assert_equal \
        [ "--env", "REDIS_URL=\"redis://c/d\"", "--env-file", ".kamal/apps/app/env/roles/workers.env" ],
        config_with_roles.role(:workers).env_args("1.1.1.3").map(&:to_s)

      assert_equal \
        "REDIS_PASSWORD=secret456\n",
        config_with_roles.role(:workers).secrets_io("1.1.1.3").read
    end
  end

  test "asset path and volume args" do
    ENV["VERSION"] = "12345"
    assert_nil config_with_roles.role(:web).asset_volume_args
    assert_nil config_with_roles.role(:workers).asset_volume_args
    assert_nil config_with_roles.role(:web).asset_path
    assert_nil config_with_roles.role(:workers).asset_path
    assert_not config_with_roles.role(:web).assets?
    assert_not config_with_roles.role(:workers).assets?

    config_with_assets = Kamal::Configuration.new(@deploy_with_roles.dup.tap { |c|
      c[:asset_path] = "foo"
    })
    assert_equal "foo", config_with_assets.role(:web).asset_path
    assert_equal "foo", config_with_assets.role(:workers).asset_path
    assert_equal [ "--volume", "$PWD/.kamal/apps/app/assets/volumes/web-12345:foo" ], config_with_assets.role(:web).asset_volume_args
    assert_nil config_with_assets.role(:workers).asset_volume_args
    assert config_with_assets.role(:web).assets?
    assert_not config_with_assets.role(:workers).assets?

    config_with_assets = Kamal::Configuration.new(@deploy_with_roles.dup.tap { |c|
      c[:servers]["web"] = { "hosts" => [ "1.1.1.1", "1.1.1.2" ], "asset_path" => "bar" }
    })
    assert_equal "bar", config_with_assets.role(:web).asset_path
    assert_nil config_with_assets.role(:workers).asset_path
    assert_equal [ "--volume", "$PWD/.kamal/apps/app/assets/volumes/web-12345:bar" ], config_with_assets.role(:web).asset_volume_args
    assert_nil config_with_assets.role(:workers).asset_volume_args
    assert config_with_assets.role(:web).assets?
    assert_not config_with_assets.role(:workers).assets?

  ensure
    ENV.delete("VERSION")
  end

  test "asset path with mount options" do
    ENV["VERSION"] = "12345"

    config_with_assets = Kamal::Configuration.new(@deploy_with_roles.dup.tap { |c|
      c[:asset_path] = "/rails/public/assets:z"
    })
    assert_equal "/rails/public/assets", config_with_assets.role(:web).asset_path
    assert_equal "z", config_with_assets.role(:web).asset_path_options
    assert_equal [ "--volume", "$PWD/.kamal/apps/app/assets/volumes/web-12345:/rails/public/assets:z" ], config_with_assets.role(:web).asset_volume_args

    config_with_assets = Kamal::Configuration.new(@deploy_with_roles.dup.tap { |c|
      c[:servers]["web"] = { "hosts" => [ "1.1.1.1", "1.1.1.2" ], "asset_path" => "/assets:ro,z" }
    })
    assert_equal "/assets", config_with_assets.role(:web).asset_path
    assert_equal "ro,z", config_with_assets.role(:web).asset_path_options
    assert_equal [ "--volume", "$PWD/.kamal/apps/app/assets/volumes/web-12345:/assets:ro,z" ], config_with_assets.role(:web).asset_volume_args

  ensure
    ENV.delete("VERSION")
  end

  test "asset extracted path" do
    ENV["VERSION"] = "12345"
    assert_equal ".kamal/apps/app/assets/extracted/web-12345", config_with_roles.role(:web).asset_extracted_directory
    assert_equal ".kamal/apps/app/assets/extracted/workers-12345", config_with_roles.role(:workers).asset_extracted_directory
  ensure
    ENV.delete("VERSION")
  end

  test "asset volume path" do
    ENV["VERSION"] = "12345"
    assert_equal ".kamal/apps/app/assets/volumes/web-12345", config_with_roles.role(:web).asset_volume_directory
    assert_equal ".kamal/apps/app/assets/volumes/workers-12345", config_with_roles.role(:workers).asset_volume_directory
  ensure
    ENV.delete("VERSION")
  end

  test "stop args with proxy" do
    assert_equal [], config_with_roles.role(:web).stop_args
  end

  test "stop args with no proxy" do
    assert_equal [ "-t", 30 ], config_with_roles.role(:workers).stop_args
  end

  test "restart policy" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "restart" => "on-failure:3", "memory" => "2g" }

    assert_equal "on-failure:3", config_with_roles.role(:workers).restart_policy
    assert_equal [ "--memory", "\"2g\"" ], config_with_roles.role(:workers).option_args
  end

  test "default restart policy" do
    assert_equal "unless-stopped", config_with_roles.role(:workers).restart_policy
  end

  test "stop args with proxy and stop_timeout" do
    @deploy_with_roles[:servers]["web"] = { "hosts" => [ "1.1.1.1", "1.1.1.2" ], "stop_timeout" => 60 }
    assert_equal [ "-t", 60 ], config_with_roles.role(:web).stop_args
  end

  test "stop args with no proxy and stop_timeout" do
    @deploy_with_roles[:servers]["workers"] = { "hosts" => [ "1.1.1.3", "1.1.1.4" ], "cmd" => "bin/jobs", "stop_timeout" => 60 }
    assert_equal [ "-t", 60 ], config_with_roles.role(:workers).stop_args
  end

  test "stop args with root stop_timeout" do
    @deploy_with_roles[:stop_timeout] = 45
    assert_equal [ "-t", 45 ], config_with_roles.role(:web).stop_args
    assert_equal [ "-t", 45 ], config_with_roles.role(:workers).stop_args
  end

  test "stop args with role stop_timeout overriding root" do
    @deploy_with_roles[:stop_timeout] = 45
    @deploy_with_roles[:servers]["web"] = { "hosts" => [ "1.1.1.1", "1.1.1.2" ], "stop_timeout" => 60 }
    assert_equal [ "-t", 60 ], config_with_roles.role(:web).stop_args
    assert_equal [ "-t", 45 ], config_with_roles.role(:workers).stop_args
  end

  test "readiness delay falls back to the root value" do
    @deploy_with_roles[:readiness_delay] = 12

    assert_equal 12, config_with_roles.role(:web).readiness_delay
    assert_equal 12, config_with_roles.role(:workers).readiness_delay
  end

  test "role readiness delay overrides the root value" do
    @deploy_with_roles[:readiness_delay] = 12
    @deploy_with_roles[:servers]["workers"] = { "hosts" => [ "1.1.1.3" ], "cmd" => "bin/jobs", "readiness_delay" => 30 }

    assert_equal 12, config_with_roles.role(:web).readiness_delay
    assert_equal 30, config_with_roles.role(:workers).readiness_delay
  end

  test "role readiness delay of zero is honoured over a non-zero root" do
    @deploy_with_roles[:readiness_delay] = 12
    @deploy_with_roles[:servers]["workers"] = { "hosts" => [ "1.1.1.3" ], "cmd" => "bin/jobs", "readiness_delay" => 0 }

    assert_equal 0, config_with_roles.role(:workers).readiness_delay
  end

  test "role specific proxy config" do
    @deploy_with_roles[:proxy] = { "response_timeout" => 15 }
    @deploy_with_roles[:servers]["workers"]["proxy"] = { "response_timeout" => 18 }

    assert_equal "15s", config_with_roles.role(:web).proxy.deploy_options[:"target-timeout"]
    assert_equal "18s", config_with_roles.role(:workers).proxy.deploy_options[:"target-timeout"]
  end

  test "readiness source is the proxy for a proxied role" do
    assert_equal :proxy, config_with_roles.role(:web).readiness_source
  end

  test "readiness source is the proxy for a non-primary role that opts into it" do
    @deploy_with_roles[:servers]["workers"]["proxy"] = true

    assert_equal :proxy, config_with_roles.role(:workers).readiness_source
  end

  test "readiness source is none for a role without a proxy or a healthcheck" do
    assert_equal :none, config_with_roles.role(:workers).readiness_source
  end

  test "readiness source is docker options when the role declares a health-cmd" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "pgrep -f bin/jobs" }

    assert_equal :docker_options, config_with_roles.role(:workers).readiness_source
  end

  test "readiness source is none when health options do not declare a healthcheck" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-interval" => "5s" }

    assert_equal :none, config_with_roles.role(:workers).readiness_source
  end

  test "readiness source is the healthcheck when the role declares one" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434 }

    assert_equal :healthcheck, config_with_roles.role(:workers).readiness_source
  end

  test "readiness source is the exec probe when the healthcheck declares one" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "exec" => "bin/ready-check" }

    assert_equal :healthcheck_exec, config_with_roles.role(:workers).readiness_source
  end

  test "an exec probe adds no docker healthcheck flags but still gates readiness" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "exec" => "bin/ready-check" }

    role = config_with_roles.role(:workers)

    assert_equal [], role.healthcheck_args
    assert role.readiness_gated?
  end

  test "readiness description names the proxy health check path" do
    @deploy_with_roles[:proxy] = { "healthcheck" => { "path" => "/healthz" } }

    assert_equal "kamal-proxy health check /healthz", config_with_roles.role(:web).readiness_description
  end

  test "readiness description names the healthcheck port and path" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434, "path" => "/readyz" }

    assert_equal "healthcheck /readyz:7434", config_with_roles.role(:workers).readiness_description
  end

  test "readiness description marks a custom healthcheck cmd" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "cmd" => "pgrep -f bin/jobs" }

    assert_equal "healthcheck (custom cmd)", config_with_roles.role(:workers).readiness_description
  end

  test "readiness description names a hand-rolled health-cmd option" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "pgrep -f bin/jobs" }

    assert_equal "docker healthcheck (options: health-cmd)", config_with_roles.role(:workers).readiness_description
  end

  test "readiness description spells out the gap when there is no readiness source" do
    @deploy_with_roles[:readiness_delay] = 12

    assert_equal "NONE (old container stops 12s after boot)", config_with_roles.role(:workers).readiness_description
  end

  test "readiness description names the exec probe command" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "exec" => "bin/ready-check" }

    assert_equal "healthcheck exec probe (bin/ready-check)", config_with_roles.role(:workers).readiness_description
  end

  test "healthcheck args are empty without a healthcheck" do
    assert_equal [], config_with_roles.role(:workers).healthcheck_args
  end

  test "healthcheck args render the docker flags" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434, "path" => "/readyz" }

    assert_equal [ "--health-cmd", "\"curl -f http://localhost:7434/readyz || exit 1\"", "--health-interval", "\"1s\"" ],
      config_with_roles.role(:workers).healthcheck_args
  end

  test "healthcheck cannot coexist with health options" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434 }
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "pgrep -f bin/jobs" }

    error = assert_raises Kamal::ConfigurationError do
      config_with_roles.role(:workers)
    end

    assert_equal "servers/workers/healthcheck: cannot be combined with options/health-cmd, remove one of them", error.message
  end

  test "empty healthcheck is not silently ignored" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = {}

    error = assert_raises Kamal::ConfigurationError do
      config_with_roles.role(:workers)
    end

    assert_equal "servers/workers/healthcheck: port is required unless cmd or exec is set", error.message
  end

  test "healthcheck rejects unknown keys" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434, "max_attempts" => 7 }

    error = assert_raises Kamal::ConfigurationError do
      config_with_roles.role(:workers)
    end

    assert_equal "servers/workers/healthcheck: unknown key: max_attempts", error.message
  end

  test "readiness is not gated for a role without a proxy or a healthcheck" do
    @deploy_with_roles[:servers]["workers"].delete("healthcheck")

    assert_not config_with_roles.role(:workers).readiness_gated?
  end

  test "readiness is gated by a healthcheck block" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434 }

    assert config_with_roles.role(:workers).readiness_gated?
  end

  test "readiness is gated by a hand-rolled health-cmd option" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "pgrep -f bin/jobs" }

    assert config_with_roles.role(:workers).readiness_gated?
  end

  test "healthcheck false is an explicit opt-out, not a healthcheck" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = false

    role = config_with_roles.role(:workers)

    assert role.readiness_gated?
    assert_nil role.healthcheck
    assert_equal [], role.healthcheck_args
    assert_equal :none, role.readiness_source
  end

  test "healthcheck true is rejected" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = true

    error = assert_raises Kamal::ConfigurationError do
      config_with_roles.role(:workers)
    end

    assert_equal "servers/workers/healthcheck: should be a hash, or false to accept no readiness gate for this role", error.message
  end

  test "invalid boolean restart policy" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "restart" => false }

    error = assert_raises Kamal::ConfigurationError do
      Kamal::Configuration.new(@deploy_with_roles)
    end

    assert_equal %(servers/workers/options/restart: should be a string. Use "no" to disable restarts), error.message
  end

  test "health option with braced expansion is rejected" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "curl -fsS http://127.0.0.1:${HEALTH_PORT}/readyz || exit 1" }

    error = assert_raises Kamal::ConfigurationError do
      Kamal::Configuration.new(@deploy_with_roles)
    end

    assert_equal "servers/workers/options/health-cmd: cannot contain ${...}, which the deploy host's shell expands at docker run time, not the container — a role env var resolves to empty. Use the bare $VAR form, which expands in the container, or a literal value", error.message
  end

  test "health option with bare expansion is allowed" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "curl -fsS http://127.0.0.1:$HEALTH_PORT/readyz || exit 1" }

    assert_equal [ "--health-cmd", "\"curl -fsS http://127.0.0.1:\\$HEALTH_PORT/readyz || exit 1\"" ],
      config_with_roles.role(:workers).option_args
  end

  test "non-health option with braced expansion is left alone" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "volume" => "${PWD}/data:/data" }

    assert_equal [ "--volume", "\"${PWD}/data:/data\"" ], config_with_roles.role(:workers).option_args
  end

  test "health option with braced expansion is rejected in a list value" do
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => [ "curl -fsS http://127.0.0.1:8080/readyz", "curl -fsS http://127.0.0.1:${HEALTH_PORT}/readyz" ] }

    error = assert_raises Kamal::ConfigurationError do
      Kamal::Configuration.new(@deploy_with_roles)
    end

    assert_match "servers/workers/options/health-cmd: cannot contain ${...}", error.message
  end

  test "no boot specialization leaves the role unpaced" do
    role = config_with_roles.role(:workers)

    assert_nil role.boot
    assert_equal({}, role.boot_runner_options(role.hosts))
  end

  test "the global boot limit never becomes per-role pacing" do
    @deploy_with_roles[:boot] = { "limit" => 2, "wait" => 10 }

    role = Kamal::Configuration.new(@deploy_with_roles).role(:workers)

    assert_equal({}, role.boot_runner_options(role.hosts))
  end

  test "boot specialization paces the role's own hosts" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => 1 }

    role = Kamal::Configuration.new(@deploy_with_roles).role(:workers)

    assert_equal 1, role.boot.limit_for(role.hosts)
    assert_equal({ in: :sequence, wait: 0 }, role.boot_runner_options(role.hosts))
  end

  test "boot percentage counts the role's hosts, not the whole deploy" do
    @deploy_with_roles[:servers]["web"] = [ "1.1.1.1", "1.1.1.2", "1.1.1.5", "1.1.1.6" ]
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => "50%" }

    role = Kamal::Configuration.new(@deploy_with_roles).role(:workers)

    assert_equal 1, role.boot.limit_for(role.hosts)
  end

  test "boot percentage counts the hosts this run actually paces, not the role's config" do
    # --roles/--hosts narrow what on_roles passes to boot_runner_options; a percentage of
    # four configured hosts must not be applied to the two the run is booting.
    @deploy_with_roles[:servers]["workers"]["hosts"] = %w[ 1.1.1.3 1.1.1.4 1.1.1.5 1.1.1.6 ]
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => "50%" }

    role = Kamal::Configuration.new(@deploy_with_roles).role(:workers)

    assert_equal({ in: :groups, limit: 2, wait: 0 }, role.boot_runner_options(role.hosts))
    assert_equal({ in: :sequence, wait: 0 }, role.boot_runner_options(%w[ 1.1.1.3 1.1.1.4 ]))
  end

  test "boot is memoized, including the unspecialized nil" do
    # Servers.new constructs every Role before Kamal::Configuration#initialize assigns
    # @boot, so the role-scoped Boot has to be built on first read, not in the initializer.
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => 1 }
    config = Kamal::Configuration.new(@deploy_with_roles)

    assert_same config.role(:workers).boot, config.role(:workers).boot

    web = config.role(:web)
    Kamal::Configuration::Boot.expects(:new).never
    2.times { assert_nil web.boot }
  end

  test "parallel_roles is rejected inside a role's boot" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "parallel_roles" => true }

    error = assert_raises Kamal::ConfigurationError do
      Kamal::Configuration.new(@deploy_with_roles)
    end

    assert_match "servers/workers/boot: unknown key: parallel_roles", error.message
  end

  private
    def config
      Kamal::Configuration.new(@deploy)
    end

    def config_with_roles
      Kamal::Configuration.new(@deploy_with_roles)
    end
end
