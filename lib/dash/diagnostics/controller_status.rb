# `dash autoscale status`, the MCP `controller_status` tool and the doctor's controller
# check: the heartbeat on the state host - which controller, where, which dash, how long
# since its last tick - read as `running`, `stale` (no tick for three of its intervals) or
# `stopped`, plus the pauses still in force. `controller` is nil when none ever ran.
class Dash::Diagnostics::ControllerStatus < Dash::Diagnostics::Base
  # `roles`: the roles this run is about (the doctor's scope); their schedules and pauses.
  def initialize(now: Time.now.utc, roles: DASH.specific_roles || DASH.config.roles)
    @now, @roles = now, roles
  end

  private
    def snapshot
      host = Dash::Autoscale::StateStore.host
      roles = @roles.select { |role| role.scaled? && role.scale.schedule.any? }.map(&:name)
      read = per_host([ host ]) do |backend, _host|
        store = Dash::Autoscale::StateStore.new(backend)
        heartbeat = store.heartbeat
        # A corrupted heartbeat is not the same as none: say so instead of "never ran".
        next { error: "heartbeat.json is not valid JSON" } if store.malformed?("heartbeat.json")

        { heartbeat: heartbeat, pauses: store.pauses }
      end.first

      return { state_host: host, roles: roles, error: read[:error] } if read[:error]

      { state_host: host, roles: roles, controller: controller(read[:heartbeat]), pauses: pauses(read[:pauses].slice(*@roles.map(&:name))) }
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
