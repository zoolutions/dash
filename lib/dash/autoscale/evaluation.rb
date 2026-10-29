# One policy evaluation for one scaled role: observes it (unless handed an observation),
# reads its signal and guards when it has a signal, brings the role's remembered state up to
# date with what it saw - unreachable clocks started or cleared, warmups of members that left
# dropped, breach windows moved - and asks Dash::Autoscale::Policy.
# Takes no action and writes nothing: the controller's tick and `dash autoscale explain`
# both call this, so explain answers exactly what the next tick would decide.
class Dash::Autoscale::Evaluation
  attr_reader :role, :now, :state, :observation

  def initialize(role:, now:, state:, pause:, observation: nil, reader: nil)
    @role, @now, @state, @pause = role, now, state, pause
    @observation = observation || Dash::Autoscale::Observation.take(role)
    @reader = reader
  end

  def decide
    # With the pool unreadable nothing is known about the members, so nothing is forgotten.
    unless observation.pool_error
      state.observe_unreachable(observation.unreachable_members.keys, now: now)
      state.keep_members(observation.member_hosts)
    end

    signal, guards, configuration_error = read_signal

    decision = Dash::Autoscale::Policy.new(role: role, now: now, time_zone: role.config.autoscale.time_zone, current: observation.current,
      history: state.history, paused_until: @pause&.ends_at, warming: state.joined, unreachable: state.unreachable,
      unreadable_baseline: observation.unreadable_baseline, pool_error: observation.pool_error,
      signal: signal, guards: guards, breach: state.breach).decide

    # A signal that cannot be configured (a missing gem, an empty secret) fails the role's
    # evaluation loudly - but only where the signal decides: a floor, a pause or an
    # unreachable member goes on without it.
    raise configuration_error if configuration_error && decision.reasons == [ "missing_data" ]

    decision
  end

  private
    def read_signal
      return [ nil, [] ] unless role.scale.signal?

      signal, guards = begin
        (@reader || Dash::Autoscale::Reader.new).read(role, at: now)
      rescue Dash::ConfigurationError => e
        error = e
        [ Dash::Autoscale::Sample.new(value: nil, at: now, error: "#{e.class}: #{e.message}"), [] ]
      end

      state.observe_signal(signal, up_above: role.scale.up_above, down_below: role.scale.down_below)
      [ signal, guards, error ]
    end
end
