require_relative "../cli_test_case"

class CliHealthcheckPollerTest < CliTestCase
  setup do
    KAMAL.configure config_file: Pathname.new(File.expand_path("test/fixtures/deploy_simple.yml")), destination: nil, version: "999"
  end

  test "wait_for_healthy returns after container reports running" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)

    statuses = [ "running", "running" ]
    output = stdouted { Kamal::Cli::Healthcheck::Poller.wait_for_healthy { statuses.shift } }

    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy prints a progress beacon on each retry" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)

    statuses = [ "starting", "starting", "running", "running" ]
    output = stdouted { Kamal::Cli::Healthcheck::Poller.wait_for_healthy { statuses.shift } }

    assert_match /Container not ready yet, retrying in 1s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container not ready yet, retrying in 2s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy raises after the deploy timeout with no beacon spam" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)
    KAMAL.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Kamal::Cli::Healthcheck::Error do
      stdouted { Kamal::Cli::Healthcheck::Poller.wait_for_healthy { "starting" } }
    end

    assert_match /container not ready after 0 seconds \(starting\)/, error.message
  end
end
