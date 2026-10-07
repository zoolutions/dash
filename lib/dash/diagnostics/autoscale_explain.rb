# `dash autoscale explain ROLE` and the MCP `autoscale_explain` tool: one live policy
# evaluation for a scaled role, from the same inputs the controller's next tick reads -
# the running containers, the pool, and the state and pauses on the primary host - with
# every input and `eligible_at`. Decides, never acts, writes nothing, needs no running
# controller. State that cannot be read is `state_error`, and the role is evaluated as if
# the controller remembered nothing.
class Dash::Diagnostics::AutoscaleExplain < Dash::Diagnostics::Base
  def initialize(role:, now: Time.now.utc)
    raise ArgumentError, "#{role} has no scale, so the autoscale controller never touches it" unless role.scaled?

    @role, @now = role, now
  end

  private
    def snapshot
      host = Dash::Autoscale::StateStore.host
      read = per_host([ host ]) do |backend, _host|
        store = Dash::Autoscale::StateStore.new(backend)
        { state: store.state, pauses: store.pauses }
      end.first

      state = Dash::Autoscale::RoleState.from(read.dig(:state, "roles", @role.name))
      pause = Dash::Autoscale::Pause.from(read.dig(:pauses, @role.name))
      decision = Dash::Autoscale::Evaluation.new(role: @role, now: @now, state: state, pause: pause).decide

      { role: @role.name, controlled: @role.scale.schedule.any?, state_host: host, state_error: read[:error], decision: decision.to_h }.compact
    end
end
