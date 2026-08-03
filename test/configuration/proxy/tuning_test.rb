require "test_helper"

class ConfigurationProxyTuningTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no tuning keys leave the deploy command unchanged" do
    options = deploy_options({})

    assert_empty options.keys.grep(/^target-(max|idle|dial|disable|try)/)
    assert_not options.key?(:"request-timeout")
    assert_not options.key?(:"path-request-timeout")
  end

  # AC1 — two different deadlines, both reachable, named apart.
  test "response_timeout and request_timeout are separate flags" do
    options = deploy_options "response_timeout" => 20, "request_timeout" => 30

    assert_equal "20s", options[:"target-timeout"]
    assert_equal "30s", options[:"request-timeout"]
  end

  # AC2 — the same builder, not a parallel copy.
  test "both path timeout maps are built by the same code path" do
    options = deploy_options \
      "path_response_timeouts" => { "/uploads" => 300 },
      "path_request_timeouts" => { "/uploads" => 600, "/stream" => 0 }

    assert_equal [ "/uploads=300s" ], options[:"path-timeout"]
    assert_equal [ "/uploads=600s", "/stream=0s" ], options[:"path-request-timeout"]
  end

  test "a path timeout may be given as a go duration string" do
    assert_equal [ "/reports=5m" ], deploy_options("path_request_timeouts" => { "/reports" => "5m" })[:"path-request-timeout"]
  end

  test "the target block becomes the pool and retry flags" do
    options = deploy_options "target" => {
      "max_conns" => 100, "max_idle_conns" => 10, "idle_conn_timeout" => 90,
      "dial_timeout" => 5, "disable_keep_alives" => true,
      "try_duration" => 30, "try_interval" => 1
    }

    assert_equal 100, options[:"target-max-conns"]
    assert_equal 10, options[:"target-max-idle-conns"]
    assert_equal "90s", options[:"target-idle-conn-timeout"]
    assert_equal "5s", options[:"target-dial-timeout"]
    assert_equal true, options[:"target-disable-keep-alives"]
    assert_equal "30s", options[:"target-try-duration"]
    assert_equal "1s", options[:"target-try-interval"]
  end

  test "disable_keep_alives false emits nothing, matching the proxy default" do
    assert_not deploy_options("target" => { "disable_keep_alives" => false }).key?(:"target-disable-keep-alives")
  end

  # AC3 — the bug e1e5c10 fixed on the proxy side. A literal 0 is a value, not
  # an absence: unlimited for max_conns, no limit for request_timeout, a single
  # attempt for try_duration.
  test "an explicit zero reaches the proxy rather than being dropped" do
    options = deploy_options \
      "request_timeout" => 0,
      "target" => {
        "max_conns" => 0, "max_idle_conns" => 0, "idle_conn_timeout" => 0,
        "dial_timeout" => 0, "try_duration" => 0
      }

    assert_equal "0s", options[:"request-timeout"]
    assert_equal 0, options[:"target-max-conns"]
    assert_equal 0, options[:"target-max-idle-conns"]
    assert_equal "0s", options[:"target-idle-conn-timeout"]
    assert_equal "0s", options[:"target-dial-timeout"]
    assert_equal "0s", options[:"target-try-duration"]
  end

  test "an explicit zero survives all the way to the command line" do
    args = configuration("request_timeout" => 0, "target" => { "max_conns" => 0 })
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--request-timeout=\"0s\""
    assert_includes args, "--target-max-conns=\"0\""
  end

  # Validation

  test "negative pool values are rejected" do
    {
      "max_conns" => "max_conns", "max_idle_conns" => "max_idle_conns",
      "idle_conn_timeout" => "idle_conn_timeout", "dial_timeout" => "dial_timeout"
    }.each_key do |key|
      error = assert_raises(Kamal::ConfigurationError) { configuration "target" => { key => -1 } }
      assert_equal "proxy/target: #{key} cannot be negative", error.message
    end
  end

  test "negative retry values are rejected" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "target" => { "try_duration" => -1 } }
    assert_equal "proxy/target: try_duration cannot be negative", error.message
  end

  test "try_interval without try_duration is rejected" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "target" => { "try_interval" => 1 } }

    assert_equal "proxy/target: try_interval has no effect without try_duration", error.message
  end

  test "try_interval with a zero try_duration is rejected too" do
    error = assert_raises(Kamal::ConfigurationError) do
      configuration "target" => { "try_duration" => 0, "try_interval" => 1 }
    end

    assert_equal "proxy/target: try_interval has no effect without try_duration", error.message
  end

  test "a negative request_timeout is rejected" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "request_timeout" => -1 }

    assert_equal "proxy/request_timeout: cannot be negative", error.message
  end

  # Sibling consistency: request_timeout already refuses negatives, and
  # kamal-proxy clamps a negative --target-timeout just as silently.
  test "a negative response_timeout is rejected" do
    error = assert_raises(Kamal::ConfigurationError) { configuration "response_timeout" => -1 }

    assert_equal "proxy/response_timeout: cannot be negative", error.message
  end

  # Zero means "use the proxy default of 100", not "keep none" - an operator
  # writing 0 to disable idle connections gets the opposite. Legal, so warn.
  test "max_idle_conns zero warns that it means the proxy default" do
    out = stderred { Kamal::Configuration.new @deploy.merge(proxy: { "target" => { "max_idle_conns" => 0 } }) }

    assert_match "max_idle_conns: 0 means the proxy default of 100, not \"keep none\"", out
  end

  test "no warning for a positive max_idle_conns" do
    out = stderred { Kamal::Configuration.new @deploy.merge(proxy: { "target" => { "max_idle_conns" => 10 } }) }

    assert_no_match(/max_idle_conns/, out)
  end

  # kamal-proxy's parsePathTimeouts rejects these; both maps go through it.
  test "a negative path timeout is rejected in either map" do
    assert_equal "proxy/path_response_timeouts: '/uploads' cannot be negative",
      assert_raises(Kamal::ConfigurationError) { configuration "path_response_timeouts" => { "/uploads" => -1 } }.message

    assert_equal "proxy/path_request_timeouts: '/uploads' cannot be negative",
      assert_raises(Kamal::ConfigurationError) { configuration "path_request_timeouts" => { "/uploads" => -1 } }.message
  end

  private
    def configuration(proxy_config)
      Kamal::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end
end
