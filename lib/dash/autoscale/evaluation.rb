# One policy evaluation for one scaled role: observes it (unless handed an observation),
# brings the role's remembered state up to date with what it saw - unreachable clocks
# started or cleared, warmups of members that left dropped - and asks Dash::Autoscale::Policy.
# Takes no action and writes nothing: the controller's tick and `dash autoscale explain`
# both call this, so explain answers exactly what the next tick would decide.
class Dash::Autoscale::Evaluation
  attr_reader :role, :now, :state, :observation

  def initialize(role:, now:, state:, pause:, observation: nil)
    @role, @now, @state, @pause = role, now, state, pause
    @observation = observation || Dash::Autoscale::Observation.take(role)
  end

  def decide
    # With the pool unreadable nothing is known about the members, so nothing is forgotten.
    unless observation.pool_error
      state.observe_unreachable(observation.unreachable_members.keys, now: now)
      state.keep_members(observation.member_hosts)
    end

    Dash::Autoscale::Policy.new(role: role, now: now, time_zone: role.config.autoscale.time_zone, current: observation.current,
      history: state.history, paused_until: @pause&.ends_at, warming: state.joined, unreachable: state.unreachable,
      unreadable_baseline: observation.unreadable_baseline, pool_error: observation.pool_error).decide
  end
end
