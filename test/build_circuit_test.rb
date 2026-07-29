require "test_helper"
require_relative "integration/build_circuit"
require_relative "integration/integration_test"

class BuildCircuitTest < ActiveSupport::TestCase
  test "starts closed" do
    circuit = BuildCircuit.new

    assert_equal 0, circuit.consecutive_failures
    assert_not circuit.tripped?
  end

  test "trips once the threshold of consecutive failures is reached" do
    circuit = BuildCircuit.new(threshold: 2)

    circuit.record_failure!
    assert_not circuit.tripped?, "one failure must still let the next test run"

    circuit.record_failure!
    assert circuit.tripped?
  end

  # A build that eventually succeeds means the runner can reach the registry
  # after all, so an earlier blip must not count towards the next one.
  test "a success resets the count" do
    circuit = BuildCircuit.new(threshold: 2)

    circuit.record_failure!
    circuit.record_success!
    circuit.record_failure!

    assert_equal 1, circuit.consecutive_failures
    assert_not circuit.tripped?
  end

  test "stays tripped once tripped" do
    circuit = BuildCircuit.new(threshold: 2)
    3.times { circuit.record_failure! }

    assert circuit.tripped?
    assert_equal 3, circuit.consecutive_failures
  end

  test "defaults to the shared threshold" do
    assert_equal BuildCircuit::THRESHOLD, BuildCircuit.new.threshold
  end

  # The message is what a maintainer reads in the CI log, so it has to name the
  # cause as infrastructure and say what to do about it.
  test "trip message names the cause and the remedy" do
    circuit = BuildCircuit.new(threshold: 2)
    2.times { circuit.record_failure! }

    assert_match(/2 consecutive/, circuit.trip_message)
    assert_match(/cannot reach/, circuit.trip_message)
    assert_match(/re-run the job/, circuit.trip_message)
  end

  # The default instance is what the integration suite accumulates into; it must
  # be the same object every time or the count would never build up.
  test "default is memoized" do
    assert_same BuildCircuit.default, BuildCircuit.default
  end

  test "build failures are a distinct error class" do
    assert_operator BuildCircuit::BuildFailed, :<, RuntimeError
  end

  # --- harness wiring, exercised without Docker --------------------------------

  test "an exhausted build ladder records exactly one failure and raises BuildFailed" do
    circuit = BuildCircuit.new(threshold: 2)
    builds = failing_build_probe(circuit)

    assert_raises(BuildCircuit::BuildFailed) { builds.call }

    assert_equal 1, circuit.consecutive_failures, "one failure per test, not per retry attempt"
  end

  # The whole point of the issue: `up --no-build` cannot build, so retrying it
  # used to re-run the entire backoff ladder for the same doomed result.
  test "a failing build runs the ladder once per test, not twice" do
    circuit = BuildCircuit.new(threshold: 2)
    attempts = 0
    builds = failing_build_probe(circuit) { attempts += 1 }

    assert_raises(BuildCircuit::BuildFailed) { builds.call }

    assert_equal 3, attempts, "expected a single 3-attempt ladder, not compose_up_with_retry doubling it"
  end

  test "two tests with a dead registry trip the circuit" do
    circuit = BuildCircuit.new(threshold: 2)
    builds = failing_build_probe(circuit)

    2.times { assert_raises(BuildCircuit::BuildFailed) { builds.call } }

    assert circuit.tripped?
  end

  test "a successful build records success" do
    circuit = BuildCircuit.new(threshold: 2)
    circuit.record_failure!

    probe = integration_probe(circuit)
    probe.stubs(:docker_compose)
    with_unbuilt_images { probe.send(:compose_up_with_retry) }

    assert_equal 0, circuit.consecutive_failures
  end

  private
    # These tests drive the real harness methods, which key off the $IMAGES_BUILT
    # global. `bin/test` loads the unit and integration suites into one process,
    # so restore whatever the integration suite had rather than clearing it -
    # otherwise a later integration test would rebuild its images for nothing.
    def with_unbuilt_images
      previously_built = $IMAGES_BUILT
      $IMAGES_BUILT = nil
      yield
    ensure
      $IMAGES_BUILT = previously_built
    end

    def integration_probe(circuit)
      IntegrationTest.new("noop").tap do |probe|
        probe.stubs(:build_circuit).returns(circuit)
        probe.stubs(:sleep)
      end
    end

    # Returns a callable that runs one test's worth of setup against a registry
    # that never answers, resetting $IMAGES_BUILT the way a fresh process would.
    def failing_build_probe(circuit, &on_build)
      probe = integration_probe(circuit)
      probe.stubs(:docker_compose)
        .with { |*args| on_build&.call if args.first == "build"; true }
        .raises(RuntimeError.new("no route to registry-1.docker.io"))

      -> do
        with_unbuilt_images do
          # The retry ladder narrates itself to stdout; keep it out of the run.
          stdouted { probe.send(:compose_up_with_retry) }
        end
      end
    end
end
