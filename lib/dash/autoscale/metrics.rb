# What `dash autoscale run --metrics-port` serves, in the Prometheus text format: per role
# its running and target containers, its members per provider state, and its signal's and
# guards' last samples as of the last tick, decision counts since the controller started,
# and when the last tick ran and how long it took. Ticks write, the metrics server thread reads, so both go through the lock.
class Dash::Autoscale::Metrics
  CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

  def initialize
    @mutex = Mutex.new
    @containers = {}
    @decisions = Hash.new(0)
    @members = {}
    @signals = {}
    @guards = {}
    @last_tick_at = @tick_duration = nil
  end

  # `members` is { role => [ provider state of each member ] }.
  def record_tick(decisions:, members:, at:, duration:)
    @mutex.synchronize do
      decisions.each do |decision|
        @containers[decision.role] = { "running" => decision.from, "target" => decision.inputs[:floor] }.compact
        decision.reasons.each { |reason| @decisions[[ decision.role, decision.action, reason ]] += 1 }
        @signals[decision.role] = decision.inputs[:signal]
        @guards[decision.role] = decision.inputs[:guards].to_a
      end

      members.each { |role, states| @members[role] = states.tally }
      @last_tick_at, @tick_duration = at, duration
    end
  end

  def render
    @mutex.synchronize do
      [
        family("dash_autoscale_containers", "gauge", "Containers of a scaled role: running, and the target the controller holds it to.",
          @containers.sort.flat_map { |role, counts| counts.sort.map { |state, count| [ { role: role, state: state }, count ] } }),
        family("dash_autoscale_decisions_total", "counter", "Decisions the controller took, per role, action and reason.",
          @decisions.sort.map { |(role, action, reason), count| [ { role: role, action: action, reason: reason }, count ] }),
        family("dash_autoscale_members", "gauge", "Pool members of a scaled role, per provider state.",
          @members.sort.flat_map { |role, states| states.sort.map { |state, count| [ { role: role, state: state }, count ] } }),
        family("dash_autoscale_signal", "gauge", "The last sample of a scaled role's signal; absent while it cannot be read.",
          @signals.sort.filter_map { |role, signal| [ { role: role, source: signal[:source] }, signal[:value] ] if signal&.dig(:value) }),
        family("dash_autoscale_guard", "gauge", "The last sample of each of a scaled role's guards, by its index in hold_when.",
          @guards.sort.flat_map { |role, guards| guards.filter_map { |guard| [ { role: role, guard: guard[:index], source: guard[:source] }, guard[:value] ] unless guard[:value].nil? } }),
        family("dash_autoscale_last_tick_timestamp_seconds", "gauge", "When the last tick finished, in Unix seconds.",
          @last_tick_at ? [ [ {}, @last_tick_at.to_i ] ] : []),
        family("dash_autoscale_tick_duration_seconds", "gauge", "How long the last tick took.",
          @tick_duration ? [ [ {}, @tick_duration.round(3) ] ] : [])
      ].join
    end
  end

  private
    def family(name, type, help, samples)
      lines = [ "# HELP #{name} #{help}", "# TYPE #{name} #{type}" ]
      lines += samples.map { |labels, value| "#{name}#{labels(labels)} #{value}" }
      lines.map { |line| "#{line}\n" }.join
    end

    def labels(labels)
      return "" if labels.empty?

      "{#{labels.map { |key, value| %(#{key}="#{escape(value)}") }.join(",")}}"
    end

    def escape(value)
      value.to_s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")
    end
end
