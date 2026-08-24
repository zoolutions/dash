require "test_helper"

class ConfigurationRoleHealthcheckTest < ActiveSupport::TestCase
  test "http check defaults to /up on the configured port" do
    assert_equal "curl -f http://localhost:7434/up || exit 1", healthcheck(port: 7434).cmd
  end

  test "http check with a custom path" do
    assert_equal "curl -f http://localhost:7434/readyz || exit 1", healthcheck(port: 7434, path: "/readyz").cmd
  end

  test "custom command wins over the http check" do
    assert_equal "pgrep -f bin/jobs", healthcheck(cmd: "pgrep -f bin/jobs").cmd
  end

  test "args default to the command and a one second interval" do
    assert_equal [ "--health-cmd", "\"pgrep -f bin/jobs\"", "--health-interval", "\"1s\"" ],
      healthcheck(cmd: "pgrep -f bin/jobs").args
  end

  test "args emit every docker healthcheck flag" do
    check = healthcheck \
      port: 7434, path: "/readyz", interval: 5, timeout: 3, retries: 3, start_period: 60, start_interval: 1

    assert_equal [
      "--health-cmd", "\"curl -f http://localhost:7434/readyz || exit 1\"",
      "--health-interval", "\"5s\"",
      "--health-timeout", "\"3s\"",
      "--health-retries", "\"3\"",
      "--health-start-period", "\"60s\"",
      "--health-start-interval", "\"1s\""
    ], check.args
  end

  test "durations pass through when they carry a unit" do
    assert_equal [ "--health-interval", "\"1m30s\"" ], healthcheck(port: 7434, interval: "1m30s").args[2..3]
  end

  test "port is required when there is no command" do
    error = assert_raises Dash::ConfigurationError do
      healthcheck(path: "/readyz")
    end

    assert_equal "servers/workers/healthcheck: port is required unless cmd or exec is set", error.message
  end

  test "command may not contain a shell expansion" do
    error = assert_raises Dash::ConfigurationError do
      healthcheck(cmd: "curl -f http://localhost:${PORT}/up")
    end

    assert_equal "servers/workers/healthcheck/cmd: cannot contain ${...}, it would expand on the deploy host, not in the container", error.message
  end

  test "exec probes are polled from the deploy host, so they emit no docker flags" do
    check = healthcheck(exec: "bin/ready-check")

    assert check.exec?
    assert_equal "bin/ready-check", check.exec
    assert_equal [], check.args
  end

  test "a healthcheck without exec is not an exec probe" do
    assert_not healthcheck(port: 7434).exec?
  end

  test "exec keeps ${...} because docker exec quotes it past the deploy host's shell" do
    assert_equal "bin/ready-check ${PORT}", healthcheck(exec: "bin/ready-check ${PORT}").exec
  end

  test "exec cannot be combined with keys that only configure docker's healthcheck" do
    { cmd: "pgrep -f bin/jobs", port: 7434, path: "/readyz", interval: 5, timeout: 3,
      retries: 3, start_period: 60, start_interval: 1 }.each do |key, value|
      error = assert_raises Dash::ConfigurationError, "expected #{key} to conflict with exec" do
        healthcheck(exec: "bin/ready-check", key => value)
      end

      assert_equal "servers/workers/healthcheck/exec: cannot be combined with #{key}, " \
        "which only configures docker's own healthcheck — an exec probe is polled from the deploy host", error.message
    end
  end


  private
    def healthcheck(**healthcheck_config)
      Dash::Configuration::Role::Healthcheck.new \
        healthcheck_config: healthcheck_config.transform_keys(&:to_s), context: "servers/workers/healthcheck"
    end
end
