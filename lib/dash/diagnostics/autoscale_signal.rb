require "socket"

# `dash autoscale signal ROLE`, the MCP `signal_sample` tool and the doctor's signal check:
# one live sample of a role's `scale.signal` and of each `scale.hold_when` guard, through
# the controller's own readers (Dash::Autoscale::Signal, Dash::Autoscale::Guard), each read
# timed. The fields are those of a decision's `inputs[:signal]` and `inputs[:guards]`, so
# a sample compares directly with what the controller logged.
#
# Read from this machine: a laptop reaches the sources by another path than the controller
# host (a direct URL, or its own `via:` tunnel), so `from` names it. Read-only, as the
# readers are: Redis LINDEX, SMEMBERS and HMGET, Postgres inside a rolled-back read-only
# transaction, a Prometheus instant query. A read that fails - a configuration error
# included - is the sample's error; nothing raises.
class Dash::Diagnostics::AutoscaleSignal < Dash::Diagnostics::Base
  # `connections` given are the caller's to close; without, the sample opens its own and
  # closes them when done.
  def initialize(role:, now: Time.now.utc, connections: nil)
    @role, @now, @connections = role, now, connections
  end

  private
    def snapshot
      return { role: @role.name, configured: false, message: "#{@role} has no scale/signal, so there is nothing to sample" } unless @role.scaled? && @role.scale.signal?

      with_connections do |connections|
        signal = timed { Dash::Autoscale::Signal.for(@role, connections).sample(at: @now) }
        guards = @role.scale.guards.each_with_index.map { |guard, index| guard_reading(guard, index, connections) }

        Dash::Autoscale::Decision.json_safe(role: @role.name, configured: true, from: Socket.gethostname,
          signal: { source: scale.signal.source }.merge(signal[:result].to_h, latency_ms: signal[:latency_ms]),
          position: position(signal[:result]), guards: guards, band: band)
      end
    end

    def scale
      @role.scale
    end

    def with_connections
      return yield @connections if @connections

      connections = Dash::Autoscale::Connections.new
      begin
        yield connections
      ensure
        connections.close
      end
    end

    # A guard read on its own, so it has its own latency.
    def guard_reading(guard, index, connections)
      read = timed { Dash::Autoscale::Guard.read([ guard ], connections, at: @now).first.sample }
      reading = Dash::Autoscale::Guard::Reading.new(index: index, source: guard.source, above: guard.above, sample: read[:result])

      reading.to_h.merge(holding: reading.holding?, latency_ms: read[:latency_ms])
    end

    def position(sample)
      return if sample.missing?

      if sample.value > scale.up_above then "above"
      elsif sample.value < scale.down_below then "below"
      else "inside"
      end
    end

    def band
      { up_above: scale.up_above, up_for: scale.up_for, down_below: scale.down_below, down_for: scale.down_for }
    end

    # { result: the Sample, latency_ms: }; a configuration error becomes the Sample's error.
    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = begin
        yield
      rescue Dash::ConfigurationError => e
        Dash::Autoscale::Sample.new(value: nil, at: @now, error: "#{e.class}: #{e.message}")
      end

      { result: result, latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) }
    end
end
