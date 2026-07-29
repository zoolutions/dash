# Circuit breaker for the integration suite's compose build.
#
# Retrying a failed build is right for a Docker Hub blip and wrong for a runner
# whose egress is dead: one CI runner spent 1h23m grinding the full retry ladder
# once per test, every attempt doomed from the first minute, while sibling matrix
# jobs pulled the same images fine. After THRESHOLD consecutive tests exhaust
# their build retries, this trips and the remaining tests skip instead.
#
# Instantiable rather than a bag of module state: `bin/test` loads the unit and
# integration suites into one process in random order, so a shared counter that
# a unit test could reset would be resettable mid-run — defeating the breaker in
# exactly the situation it exists for. The integration suite accumulates into
# BuildCircuit.default; tests use their own instances.
class BuildCircuit
  THRESHOLD = 2

  # Raised when the build's own retry ladder is exhausted, so callers can tell a
  # dead build apart from an unrelated RuntimeError out of docker compose.
  class BuildFailed < RuntimeError; end

  attr_reader :consecutive_failures, :threshold

  def self.default
    @default ||= new
  end

  def initialize(threshold: THRESHOLD)
    @threshold = threshold
    @consecutive_failures = 0
  end

  def record_failure!
    @consecutive_failures += 1
  end

  def record_success!
    @consecutive_failures = 0
  end

  def tripped?
    consecutive_failures >= threshold
  end

  def trip_message
    "Skipping: #{consecutive_failures} consecutive compose builds failed after exhausting their retries - " \
      "this runner most likely cannot reach the image registry. Infrastructure, not a test failure - re-run the job."
  end
end
