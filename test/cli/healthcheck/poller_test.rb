require_relative "../cli_test_case"

class CliHealthcheckPollerTest < CliTestCase
  setup do
    KAMAL.configure config_file: Pathname.new(File.expand_path("test/fixtures/deploy_with_readiness_sources.yml")), destination: nil, version: "999"
  end

  test "wait_for_healthy returns after the container reports healthy" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)

    output = stdouted { wait_for_healthy(:listener, "healthy") }

    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy prints a progress beacon on each retry" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)

    output = stdouted { wait_for_healthy(:listener, "starting", "starting", "healthy") }

    assert_match /Container not ready yet, retrying in 1s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container not ready yet, retrying in 2s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy raises after the deploy timeout with no beacon spam" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)
    KAMAL.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Kamal::Cli::Healthcheck::Error do
      stdouted { wait_for_healthy(:listener, "starting") }
    end

    assert_match /container not ready after 0 seconds \(starting\)/, error.message
  end

  test "a role with no readiness gate warns that only the readiness delay stands in the way" do
    Kamal::Cli::Healthcheck::Poller.expects(:sleep).with(7)

    output = stdouted { wait_for_healthy(:workers, "no-healthcheck:running") }

    assert_match /workers has no healthcheck/, output
    assert_match /accepting the container as ready after the 7s readiness delay alone/, output
    assert_match /Container is healthy!/, output
  end

  test "a role that opted out with healthcheck false is accepted without the warning" do
    Kamal::Cli::Healthcheck::Poller.expects(:sleep).with(2)

    output = stdouted { wait_for_healthy(:silent, "no-healthcheck:running") }

    assert_no_match /has no healthcheck/, output
    assert_match /Container is healthy!/, output
  end

  test "a declared healthcheck that never reached the container fails as drift, without retrying" do
    Kamal::Cli::Healthcheck::Poller.expects(:sleep).never
    calls = 0

    error = assert_raises Kamal::Cli::Healthcheck::DriftError do
      stdouted do
        Kamal::Cli::Healthcheck::Poller.wait_for_healthy(role: KAMAL.config.role(:listener)) do
          calls += 1
          "no-healthcheck:running"
        end
      end
    end

    assert_equal 1, calls
    assert_match /listener declares a healthcheck but the container reports none/, error.message
  end

  test "a hand-rolled health-cmd option that never reached the container fails as drift" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)

    error = assert_raises Kamal::Cli::Healthcheck::DriftError do
      stdouted { wait_for_healthy(:pulse, "no-healthcheck:running") }
    end

    assert_match /pulse declares a healthcheck but the container reports none/, error.message
  end

  test "a healthcheck-less container that is not running reports its docker state" do
    Kamal::Cli::Healthcheck::Poller.stubs(:sleep)
    KAMAL.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Kamal::Cli::Healthcheck::Error do
      stdouted { wait_for_healthy(:workers, "no-healthcheck:exited") }
    end

    assert_match /container not ready after 0 seconds \(no-healthcheck:exited\)/, error.message
  end

  private
    # Yields each status in turn, then repeats the last one for every further poll.
    def wait_for_healthy(role_name, *statuses)
      Kamal::Cli::Healthcheck::Poller.wait_for_healthy(role: KAMAL.config.role(role_name)) do
        statuses.length > 1 ? statuses.shift : statuses.first
      end
    end
end
