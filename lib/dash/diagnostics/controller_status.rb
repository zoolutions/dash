# `dash autoscale status`, the MCP `controller_status` tool and the doctor's controller
# check: the heartbeat on the primary host - which controller, where, which dash, how long
# since its last tick - read as `running`, `stale` (no tick for three of its intervals) or
# `stopped`, plus the pauses still in force. `controller` is nil when none ever ran.
class Dash::Diagnostics::ControllerStatus < Dash::Diagnostics::Base
  def initialize(now: Time.now.utc)
    @now = now
  end

  private
    def snapshot
      host = Dash::Autoscale::StateStore.host
      roles = DASH.config.scaled_roles.select { |role| role.scale.schedule.any? }.map(&:name)
      read = per_host([ host ]) do |backend, _host|
        store = Dash::Autoscale::StateStore.new(backend)
        { heartbeat: store.heartbeat, pauses: store.pauses }
      end.first

      return { state_host: host, roles: roles, error: read[:error] } if read[:error]

      { state_host: host, roles: roles, controller: controller(read[:heartbeat]), pauses: pauses(read[:pauses]) }
    end

    def controller(heartbeat)
      return if heartbeat.empty?

      lease = Dash::Autoscale::Lease.new(heartbeat, now: @now)
      status = if lease.stopped? then "stopped" elsif lease.alive? then "running" else "stale" end

      heartbeat.symbolize_keys.merge(status: status, age_seconds: lease.age)
    end

    def pauses(pauses)
      pauses.filter_map do |role, hash|
        pause = Dash::Autoscale::Pause.from(hash)
        { role: role }.merge(pause.to_h.symbolize_keys) if pause.active?(@now)
      end.sort_by { |pause| pause[:role] }
    end
end
