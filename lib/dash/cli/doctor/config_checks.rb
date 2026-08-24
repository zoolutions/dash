# Checks that only read the configuration — no SSH, no network. They report problems
# that are visible in deploy.yml alone, so they still run when every host is unreachable.
class Dash::Cli::Doctor::ConfigChecks
  def run
    readiness_results
  end

  private
    def result(check, target, status, detail)
      Dash::Cli::Doctor::Result.new(check, target, status, detail)
    end

    def readiness_results
      DASH.roles.map { |role| readiness_check(role) }
    end

    def readiness_check(role)
      if role.readiness_source != :none
        result :readiness, role.name, :ok, role.readiness_description
      elsif role.readiness_gated?
        # readiness_gated? with no source left is `healthcheck: false` — the gap is deliberate.
        result :readiness, role.name, :ok, "healthcheck: false — accepted #{role.readiness_delay}s after the container starts"
      else
        result :readiness, role.name, :warn, "no healthcheck — the old container stops #{role.readiness_delay}s after the new one starts; " \
          "add a `healthcheck:` block, or opt out with `healthcheck: false`"
      end
    end
end
