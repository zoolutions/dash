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

      [ sample[:signal][:detail] && !sample[:signal][:error] ? proxy_result(role, sample[:signal], from) : source_result(role.name, sample[:signal], from),
        *sample[:guards].map { |guard| guard_result("#{role.name} hold_when/#{guard[:index]}", guard, from) } ]
    end

    # A proxy signal answers with how it got its number: how much traffic, from which hosts,
    # and whether the app or dash-proxy timed it. A host that did not answer warns; so does
    # a queue time that is only dash-proxy's wait for a connection with nothing capping the
    # connections, since that wait stays near 0 whatever the app's backlog.
    def proxy_result(role, read, from)
      detail = read[:detail]
      answered, failed = detail[:hosts].partition { |host| host[:error].nil? }
      traffic = if detail[:requests].zero?
        "no requests in the last #{detail[:window_seconds]}s"
      else
        "p95 of #{detail[:requests]} requests over #{detail[:window_seconds]}s on #{answered.size} #{"host".pluralize(answered.size)}"
      end

      warnings = failed.map { |host| "#{host[:host]} did not answer: #{host[:error]}" }
      if detail[:requests].positive? && detail.dig(:measured_by, :app).zero? && role.proxy.target_max_conns.nil?
        warnings << "every request was timed by dash-proxy's wait for a connection, which stays near 0 without proxy/target/max_conns: " \
          "send Server-Timing: queue;dur=<ms> from the app or set max_conns to its thread count (dash docs role)"
      end

      result role.name, warnings.empty? ? :ok : :warn,
        [ "#{read[:source]} answered #{read[:value]}#{detail[:unit]} (#{traffic}) in #{read[:latency_ms]}ms, #{from}", *warnings ].join("; ")
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
