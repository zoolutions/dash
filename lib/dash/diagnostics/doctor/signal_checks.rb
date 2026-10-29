# Whether each signalled role's `scale.signal` source and `scale.hold_when` guards answer,
# through Dash::Diagnostics::AutoscaleSignal - the reads the controller makes. Each result
# names the value, the latency and the machine it was read from: a doctor run on a laptop
# reaches the sources by another path than the controller host does. A source that does
# not answer fails; one that answers without a number, and a guard holding a scale-out, warn.
class Dash::Diagnostics::Doctor::SignalChecks
  # Within the run's --roles, like the other checks. No signalled role: no result.
  # One set of connections (and `via:` tunnels) for every role: the sources are the app's.
  def run
    roles = Dash::Diagnostics::Doctor.scoped_roles.select { |role| role.scaled? && role.scale.signal? }
    return [] if roles.empty?

    connections = Dash::Autoscale::Connections.new
    begin
      roles.flat_map { |role| role_results(role, connections) }
    ensure
      connections.close
    end
  end

  private
    def role_results(role, connections)
      sample = Dash::Diagnostics::AutoscaleSignal.new(role: role, connections: connections).to_h
      from = "from this machine (#{sample[:from]})"

      [ source_result(role.name, sample[:signal], from),
        *sample[:guards].map { |guard| guard_result("#{role.name} hold_when/#{guard[:index]}", guard, from) } ]
    end

    def source_result(target, read, from)
      if read[:error]
        result target, :fail, "#{read[:source]} did not answer #{from}: #{read[:error]}"
      elsif read[:value].nil?
        result target, :warn, "#{read[:source]} answered with no value in #{read[:latency_ms]}ms, #{from}"
      else
        result target, :ok, "#{read[:source]} answered #{read[:value]} in #{read[:latency_ms]}ms, #{from}"
      end
    end

    def guard_result(target, guard, from)
      return source_result(target, guard, from) if guard[:error]
      return result(target, :warn, "#{guard[:source]} answered with no value in #{guard[:latency_ms]}ms, #{from}; without a value it holds a scale-out") if guard[:value].nil?

      if guard[:holding]
        result target, :warn, "#{guard[:source]} answered #{guard[:value]} in #{guard[:latency_ms]}ms, #{from}; above #{guard[:above]}, so it holds a scale-out"
      else
        source_result(target, guard, from)
      end
    end

    def result(target, status, detail)
      Dash::Diagnostics::Doctor::Result.new(:signal, target, status, detail)
    end
end
