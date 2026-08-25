require "test_helper"

class ConfigurationProxyRunFlagsTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no new keys leave the run command byte-identical" do
    assert_equal "kamal-proxy run --recheck-targets-on-restore", run_config({}).run_command
  end

  test "the named run keys become flags" do
    run = run_config \
      "log_format" => "text", "trace_context" => "generate", "min_tls" => "1.3",
      "http3" => true, "reuse_port" => true, "ignore_restore_errors" => true,
      "read_header_timeout" => 10, "read_timeout" => 30, "write_timeout" => 30,
      "idle_timeout" => 60, "shutdown_timeout" => 15,
      "metrics_allow_ips" => [ "10.0.0.0/8" ]

    command = run.run_command

    assert_match "--log-format \"text\"", command
    assert_match "--trace-context \"generate\"", command
    assert_match "--min-tls \"1.3\"", command
    assert_match "--http3", command
    assert_match "--reuse-port", command
    assert_match "--ignore-restore-errors", command
    assert_match "--read-header-timeout \"10s\"", command
    assert_match "--read-timeout \"30s\"", command
    assert_match "--write-timeout \"30s\"", command
    assert_match "--idle-timeout \"60s\"", command
    assert_match "--shutdown-timeout \"15s\"", command
    assert_match "--metrics-allow-ip \"10.0.0.0/8\"", command
  end

  test "proxy protocol and its allow list" do
    command = run_config("proxy_protocol" => true, "proxy_protocol_allow_ips" => [ "10.0.0.0/8", "192.168.0.0/16" ]).run_command

    assert_match "--proxy-protocol", command
    assert_match "--proxy-protocol-allow-ip \"10.0.0.0/8\"", command
    assert_match "--proxy-protocol-allow-ip \"192.168.0.0/16\"", command
  end

  test "booleans left false emit nothing, matching the proxy defaults" do
    assert_equal "kamal-proxy run --recheck-targets-on-restore",
      run_config("http3" => false, "reuse_port" => false, "proxy_protocol" => false).run_command
  end

  # A zero disables these timeouts rather than meaning "unset".
  test "an explicit zero timeout reaches the proxy" do
    assert_match "--read-timeout \"0s\"", run_config("read_timeout" => 0).run_command
  end

  # AC1
  test "every new run key moves config_digest" do
    base = run_config({}).config_digest

    {
      "log_format" => "text", "trace_context" => "off", "min_tls" => "1.3",
      "http3" => true, "reuse_port" => true, "ignore_restore_errors" => true,
      "proxy_protocol" => true, "read_header_timeout" => 10, "read_timeout" => 30,
      "write_timeout" => 30, "idle_timeout" => 60, "shutdown_timeout" => 15,
      "metrics_allow_ips" => [ "10.0.0.0/8" ]
    }.each do |key, value|
      assert_not_equal base, run_config(key => value).config_digest, "expected #{key} to move config_digest"
    end
  end

  # The escape hatch — run.flags is kamal-proxy run, run.options is docker run

  test "run.flags are optionized onto the run command" do
    command = run_config("flags" => { "some-new-flag" => "value", "another-new-flag" => true }).run_command

    assert_match "--some-new-flag \"value\"", command
    assert_match "--another-new-flag", command
  end

  test "run.flags is distinct from run.options" do
    run = run_config "flags" => { "some-new-flag" => "value" }, "options" => { "memory" => "512m" }

    assert_match "--some-new-flag \"value\"", run.run_command
    assert_no_match(/some-new-flag/, run.docker_options_args.join(" "))

    assert_match "--memory", run.docker_options_args.join(" ")
    assert_no_match(/memory/, run.run_command)
  end

  test "run.flags moves config_digest" do
    assert_not_equal run_config({}).config_digest, run_config("flags" => { "some-new-flag" => "v" }).config_digest
  end

  # AC2 — reject the duplicate rather than emitting the flag twice
  test "a run.flags key colliding with a named key is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      run_config "log_format" => "text", "flags" => { "log-format" => "json" }
    end

    assert_equal "proxy/run/flags: log-format is already set by a named key - remove one of them", error.message
  end

  test "a run.flags key colliding with a flag the gem always emits is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      run_config "flags" => { "recheck-targets-on-restore" => false }
    end

    assert_equal "proxy/run/flags: recheck-targets-on-restore is already set by a named key - remove one of them",
      error.message
  end

  test "a run.flags key for something the gem does not emit is fine" do
    assert run_config("log_format" => "text", "flags" => { "some-new-flag" => "v" })
  end

  # exclude_metrics_paths is a deploy flag, not a run flag

  test "exclude_metrics_paths lands on the deploy command" do
    config = Dash::Configuration.new @deploy.merge(proxy: { "exclude_metrics_paths" => [ "/up", "/health" ] })

    assert_equal [ "/up", "/health" ], config.proxy.deploy_options[:"exclude-metrics-path"]
    assert_no_match(/exclude-metrics-path/, run_config({}).run_command)
  end

  # Validation — kamal-proxy rejects these in preRun, which kills the container
  # at boot rather than failing the deploy.

  test "an unknown log_format is rejected" do
    assert_equal "proxy/run: log_format 'yaml' is not a log format - use json or text",
      proxy_error("log_format" => "yaml")
  end

  test "logfmt is accepted as an alias for text" do
    assert proxy_config("log_format" => "logfmt")
  end

  test "an unknown trace_context is rejected" do
    assert_equal "proxy/run: trace_context 'on' is not a trace context mode - use off, propagate or generate",
      proxy_error("trace_context" => "on")
  end

  test "an unknown min_tls is rejected" do
    assert_equal "proxy/run: min_tls '1.4' is not a TLS version - use 1.2 or 1.3",
      proxy_error("min_tls" => "1.4")
  end

  # The flag exists to narrow what the listener negotiates, never to widen it.
  test "min_tls 1.0 and 1.1 get their own message" do
    assert_equal "proxy/run: min_tls 1.0 cannot be enabled - the lowest accepted minimum is 1.2",
      proxy_error("min_tls" => "1.0")
  end

  test "min_tls accepts the spellings kamal-proxy normalizes" do
    assert proxy_config("min_tls" => "tls1_2")
    assert proxy_config("min_tls" => 1.3)
  end

  test "a malformed CIDR in either allow list is rejected" do
    assert_equal "proxy/run/metrics_allow_ips: 'nope' is not a valid address or CIDR range",
      proxy_error("metrics_allow_ips" => [ "nope" ])

    assert_equal "proxy/run/proxy_protocol_allow_ips: 'nope' is not a valid address or CIDR range",
      proxy_error("proxy_protocol" => true, "proxy_protocol_allow_ips" => [ "nope" ])
  end

  test "a negative timeout is rejected" do
    assert_equal "proxy/run: read_timeout cannot be negative", proxy_error("read_timeout" => -1)
  end

  # AC3 — a warning, not an error: a proxy on a private network with no other
  # route in is a legitimate configuration.
  test "proxy_protocol without an allow list warns" do
    out = stderred { proxy_config("proxy_protocol" => true) }

    assert_match "proxy_protocol is enabled without proxy_protocol_allow_ips", out
  end

  test "no warning once the allow list is set" do
    out = stderred { proxy_config("proxy_protocol" => true, "proxy_protocol_allow_ips" => [ "10.0.0.0/8" ]) }

    assert_no_match(/proxy_protocol is enabled without/, out)
  end

  private
    def run_config(run)
      Dash::Configuration::Proxy::Run.new Dash::Configuration.new(@deploy), run_config: run
    end

    def proxy_config(run)
      Dash::Configuration.new @deploy.merge(proxy: { "run" => run })
    end

    def proxy_error(run)
      assert_raises(Dash::ConfigurationError) { proxy_config(run) }.message
    end
end
