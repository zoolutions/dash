# Whether the autoscale controller is running, for apps that need one: a role with a
# `scale.schedule` changes capacity only while `dash autoscale run` ticks. A missing,
# stale or stopped heartbeat warns, and so does every pause still in force. A state host
# that does not answer is a warning, never an exception.
class Dash::Diagnostics::Doctor::ControllerChecks
  def initialize(now: Time.now.utc)
    @now = now
  end

  # Within the run's --roles, like the other checks.
  def run
    roles = Dash::Diagnostics::Doctor.scoped_roles
    return [] if roles.none? { |role| role.scaled? && role.scale.schedule.any? }

    status = Dash::Diagnostics::ControllerStatus.new(now: @now, roles: roles).to_h
    return [ result(status[:state_host], :warn, "could not read the controller heartbeat (#{status[:error]})") ] if status[:error]

    [ controller_result(status), *status[:pauses].map { |pause| pause_result(pause) } ]
  end

  private
    def result(target, status, detail)
      Dash::Diagnostics::Doctor::Result.new(:controller, target, status, detail)
    end

    def controller_result(status)
      host, controller = status[:state_host], status[:controller]
      return result(host, :warn, "no controller has run; #{status[:roles].join(", ")} have a schedule that only dash autoscale run carries out") unless controller

      name = "controller #{controller[:controller_id]} on #{controller[:hostname]}"

      case controller[:status]
      when "running"
        result host, :ok, "#{name} (dash #{controller[:version]}) ticked #{controller[:age_seconds]}s ago, for #{status[:roles].join(", ")}"
      when "stopped"
        result host, :warn, "#{name} stopped at #{controller[:stopped_at]}"
      else
        result host, :warn, "#{name} last ticked #{controller[:age_seconds]}s ago (interval #{controller[:interval]}s), it looks stopped or stuck"
      end
    end

    def pause_result(pause)
      until_text = pause[:until] == Dash::Autoscale::Pause::INDEFINITE ? "until resumed" : "until #{pause[:until]}"
      result pause[:role], :warn, "paused by #{pause[:by] || "unknown"} #{until_text}"
    end
end
