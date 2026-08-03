require "test_helper"

class ConfigurationProxyLifecycleTest < ActiveSupport::TestCase
  SOCKET = { "run" => { "docker_socket" => "/var/run/docker.sock" } }.freeze

  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no lifecycle keys leave the deploy command unchanged" do
    assert_empty deploy_options({}).keys.grep(/affinity|sleep|wake/)
  end

  # Session affinity

  test "session affinity emits a bare flag and an optional cookie name" do
    assert_equal true, deploy_options("session_affinity" => { "enabled" => true })[:"session-affinity"]
    assert_not deploy_options("session_affinity" => { "enabled" => true }).key?(:"session-affinity-cookie")

    options = deploy_options "session_affinity" => { "enabled" => true, "cookie" => "_kamal_affinity" }
    assert_equal "_kamal_affinity", options[:"session-affinity-cookie"]
  end

  test "session affinity disabled emits nothing" do
    assert_empty deploy_options("session_affinity" => { "enabled" => false }).keys.grep(/affinity/)
  end

  test "a cookie without enabled is rejected" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "session_affinity" => { "cookie" => "_pin" } }

    assert_equal "proxy/session_affinity: cookie has no effect without enabled: true", error.message
  end

  # net/http silently drops a cookie with an invalid name, which looks exactly
  # like affinity not working.
  test "an invalid cookie name is rejected" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "session_affinity" => { "enabled" => true, "cookie" => "bad name" }
    end

    assert_equal "proxy/session_affinity: cookie 'bad name' is not a valid cookie name", error.message
  end

  # Sleep

  test "sleep emits durations in seconds and repeated container flags" do
    options = deploy_options SOCKET.merge(
      "sleep" => { "after" => 300, "containers" => [ "app-web", "app-worker" ], "wake_timeout" => 30 }
    )

    assert_equal "300s", options[:"sleep-after"]
    assert_equal "30s", options[:"wake-timeout"]
    assert_equal [ "app-web", "app-worker" ], options[:"sleep-container"]
  end

  test "each sleep container is its own repeated flag" do
    args = configuration(SOCKET.merge("sleep" => { "after" => 300, "containers" => [ "a", "b" ] }))
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_equal [ "--sleep-container=\"a\"", "--sleep-container=\"b\"" ], args.grep(/^--sleep-container=/)
  end

  test "containers and wake_timeout without after are rejected" do
    assert_equal "proxy/sleep: containers has no effect without after",
      assert_raises(Kamal::ConfigurationError) { configuration "sleep" => { "containers" => [ "a" ] } }.message

    assert_equal "proxy/sleep: wake_timeout has no effect without after",
      assert_raises(Kamal::ConfigurationError) { configuration "sleep" => { "wake_timeout" => 30 } }.message
  end

  test "negative durations are rejected" do
    negative_after = assert_raises(Kamal::ConfigurationError) { configuration SOCKET.merge("sleep" => { "after" => -1 }) }
    assert_equal "proxy/sleep: after cannot be negative", negative_after.message

    negative_wake = assert_raises(Kamal::ConfigurationError) do
      configuration SOCKET.merge("sleep" => { "after" => 300, "wake_timeout" => -1 })
    end
    assert_equal "proxy/sleep: wake_timeout cannot be negative", negative_wake.message
  end

  # A sleeping backend cannot answer an on-demand TLS probe, and waking one would
  # let any SNI on the internet start a container.
  test "sleep cannot be combined with on-demand TLS" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration SOCKET.merge("ssl" => { "on_demand_url" => "/ask" }, "sleep" => { "after" => 300 })
    end

    assert_equal "proxy/sleep: after cannot be combined with ssl/on_demand_url - " \
      "a sleeping target cannot answer the ask endpoint, and waking one would let any hostname start a container",
      error.message
  end

  # The docker socket

  test "docker_socket reaches the run command and mounts the socket" do
    run = run_config "docker_socket" => "/var/run/docker.sock"

    assert_match "--docker-socket \"/var/run/docker.sock\"", run.run_command
    assert_includes run.docker_options_args.join(" "), "--volume /var/run/docker.sock:/var/run/docker.sock"
  end

  test "no docker_socket means no flag and no mount" do
    run = run_config({})

    assert_no_match(/docker-socket/, run.run_command)
    assert_no_match(/docker\.sock/, run.docker_options_args.join(" "))
  end

  test "changing the docker socket changes config_digest" do
    assert_not_equal run_config({}).config_digest,
      run_config("docker_socket" => "/var/run/docker.sock").config_digest
  end

  # AC2 — the boot-time prerequisite for a deploy-time key, named rather than
  # deferred to a hung request.
  test "sleep without a docker socket names the key that is missing" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "sleep" => { "after" => 300 } }

    assert_equal "Role(s) web: proxy/sleep requires proxy/run/docker_socket - kamal-proxy can only stop and " \
      "start containers through the container runtime socket, and it is not mounted into the proxy without it",
      error.message
  end

  test "a role inheriting docker_socket from the root proxy is accepted" do
    config = Kamal::Configuration.new @deploy.merge(
      servers: { "web" => { "hosts" => [ "1.1.1.1" ] } },
      proxy: SOCKET.merge("sleep" => { "after" => 300 })
    )

    assert_equal "300s", config.role(:web).proxy.deploy_options[:"sleep-after"]
  end

  private
    def configuration(proxy_config)
      Kamal::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end

    def run_config(run)
      Kamal::Configuration::Proxy::Run.new Kamal::Configuration.new(@deploy), run_config: run
    end
end
