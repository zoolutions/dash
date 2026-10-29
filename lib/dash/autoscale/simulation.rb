require "json"

# `dash autoscale simulate --samples FILE`: replays a `dash autoscale run --record` file
# through Dash::Autoscale::Policy with the thresholds in deploy.yml now, to try a band, a
# step or a cooldown against a day that happened before deploying it.
#
# Each role starts at the count its first tick recorded. Every tick hands the policy that
# tick's recorded signal and guard readings with the simulated count and a simulated
# RoleState: the breach windows and the last scale times are worked out again with the
# current thresholds (the recorded ones were measured against the old band), and a
# simulated action changes the count at once. A scale-out onto more hosts warms them up for
# `scale.warmup`, as joined members do. The world's own holds are replayed: a recorded
# pause, an unreadable pool, unreadable baseline hosts.
#
# Known limits, so a replay with the same thresholds can differ from what ran:
# - the recorded signal is what the queue did with the containers that actually ran, not
#   with the simulated ones;
# - a simulated action's cooldown and warmup start at its tick, where live they start once
#   `dash scale set` returns (a join can take minutes), so the simulation can act again a
#   tick or more early;
# - the breach windows start empty, so a recording that begins inside a breach scales
#   `up.for` (or `down.for`) later than live did.
class Dash::Autoscale::Simulation
  ACTIONS = %w[ scale_out scale_in ].freeze

  # `roles`: role names to replay, or nil for every role in the file.
  def initialize(path:, config:, roles: nil)
    @path, @config, @roles = path, config, roles
  end

  def run
    ticks, errors = read
    replays, skipped = [], []

    ticks.group_by { |_, decision| decision["role"] }.each do |name, role_ticks|
      next if @roles && !@roles.include?(name)

      role = @config.role(name)
      if role&.scaled? && role.controlled?
        replays << Replay.new(role, role_ticks).to_h
      else
        skipped << { role: name, reason: role ? "#{name} has no scale/schedule or scale/signal in deploy.yml" : "no role named #{name} in deploy.yml" }
      end
    end

    { file: @path, roles: replays, skipped: skipped, errors: errors }
  end

  private
    # [ [ at, recorded decision ] in file order, [ { line:, error: } ] ]
    def read
      ticks, errors = [], []

      File.foreach(@path).with_index(1) do |line, number|
        next if line.strip.empty?

        tick = JSON.parse(line)
        at = Dash::Autoscale::Timestamp.parse(tick["at"]) if tick.is_a?(Hash)
        decisions = tick["decisions"] if tick.is_a?(Hash)
        unless at && decisions.is_a?(Array) && decisions.all? { |decision| decision.is_a?(Hash) && decision["role"].is_a?(String) }
          raise ArgumentError, "line is not a recorded tick: it needs an at time and a list of decisions, each naming its role"
        end

        decisions.each { |decision| ticks << [ at, decision ] }
      rescue JSON::ParserError, ArgumentError => e
        errors << { line: number, error: e.message }
      end

      [ ticks, errors ]
    end

    # One role's replay over its recorded ticks.
    class Replay
      def initialize(role, ticks)
        @role, @scale, @ticks = role, role.scale, ticks.sort_by(&:first)
        first = @ticks.map { |_, decision| decision["inputs"] }.find { |inputs| inputs.is_a?(Hash) }.to_h
        @state = Dash::Autoscale::RoleState.new(last_scale_out_at: Dash::Autoscale::Timestamp.parse(first["last_scale_out_at"]),
          last_scale_in_at: Dash::Autoscale::Timestamp.parse(first["last_scale_in_at"]))
        @count = @ticks.map { |_, decision| decision["from"] }.find { |from| from.is_a?(Integer) }
        @actions, @counts, @not_replayable, @joins = [], [], 0, 0
      end

      def to_h
        replay

        { role: @role.name, ticks: @ticks.size, replayed: @ticks.size - @not_replayable, not_replayable: @not_replayable,
          unrecorded_guards: unrecorded_guards, actions: @actions.map { |decision| decision.to_h.merge(summary: decision.summary) },
          simulated: summary(@actions.count { |decision| decision.action == "scale_out" }, @actions.count { |decision| decision.action == "scale_in" }, @counts),
          recorded: summary(*recorded_actions, recorded_counts) }.compact
      end

      private
        def replay
          @ticks.each do |at, recorded|
            inputs = recorded["inputs"].is_a?(Hash) ? recorded["inputs"] : {}

            if @count.nil? || (@scale.signal? && !inputs["signal"].is_a?(Hash))
              @not_replayable += 1
            else
              act(at, decide(at, recorded, inputs))
            end

            @counts << [ at, @count ]
          end
        end

        def decide(at, recorded, inputs)
          signal = sample(inputs["signal"], at) if @scale.signal?
          @state.observe_signal(signal, up_above: @scale.up_above, down_below: @scale.down_below) if signal

          Dash::Autoscale::Policy.new(role: @role, now: at, time_zone: @role.config.autoscale.time_zone, current: @count,
            history: @state.history, paused_until: paused_until(inputs["paused_until"]), warming: @state.joined,
            unreadable_baseline: inputs["unreadable_baseline"].is_a?(Hash) ? inputs["unreadable_baseline"] : {},
            pool_error: (recorded["error"] if recorded["reasons"] == [ "pool_unreadable" ]),
            signal: signal, guards: (guards(inputs["guards"], at) if @scale.signal?).to_a, breach: @state.breach).decide
        end

        def act(at, decision)
          return unless ACTIONS.include?(decision.action)

          new_hosts = hosts(decision.to) - hosts(@count)
          @state.scaled(decision.action, now: at)
          @state.joined_at(new_hosts.times.map { "simulated-#{@joins += 1}" }, now: at) if decision.action == "scale_out" && new_hosts.positive?
          @count = decision.to
          @actions << decision
        end

        # As Dash::Configuration::Role::Scale#splittable? reckons it.
        def hosts(count)
          [ (count.to_f / @scale.replicas.max).ceil, @scale.min ].max
        end

        def sample(recorded, at)
          Dash::Autoscale::Sample.new(value: recorded["value"], at: Dash::Autoscale::Timestamp.parse(recorded["at"]) || at, error: recorded["error"])
        end

        # The recorded readings against the current bounds. A guard with no recording at its
        # index, or one of another source (hold_when reordered or changed), is left out.
        def guards(recorded, at)
          @scale.guards.each_with_index.filter_map do |guard, index|
            next unless (reading = recorded_reading(recorded, guard, index))

            Dash::Autoscale::Guard::Reading.new(index: index, source: guard.source, above: guard.above, sample: sample(reading, at))
          end
        end

        def recorded_reading(recorded, guard, index)
          Array(recorded).find { |reading| reading.is_a?(Hash) && reading["index"] == index && reading["source"] == guard.source }
        end

        # The current guards no replayed tick has a recording for.
        def unrecorded_guards
          return unless @scale.signal?

          recorded = @ticks.filter_map { |_, decision| decision["inputs"] if decision["inputs"].is_a?(Hash) && decision["inputs"]["signal"].is_a?(Hash) }
          return if recorded.empty?

          missing = @scale.guards.each_with_index.count { |guard, index| recorded.none? { |inputs| recorded_reading(inputs["guards"], guard, index) } }
          missing if missing.positive?
        end

        def paused_until(recorded)
          recorded == Dash::Autoscale::Pause::INDEFINITE ? :indefinite : Dash::Autoscale::Timestamp.parse(recorded)
        end

        def recorded_actions
          ACTIONS.map { |action| @ticks.count { |_, decision| decision["action"] == action } }
        end

        # What ran after each recorded tick: where an action took it, else where it stood.
        def recorded_counts
          last = nil
          @ticks.map { |at, decision| [ at, last = [ decision["to"], decision["from"] ].find { |count| count.is_a?(Integer) } || last ] }
        end

        # Container-seconds: each count held until the role's next tick.
        def summary(scale_outs, scale_ins, counts)
          counts = counts.reject { |_, count| count.nil? }
          seconds = counts.each_cons(2).sum { |(at, count), (next_at, _)| count * (next_at - at) }

          { scale_outs: scale_outs, scale_ins: scale_ins, peak: counts.map(&:last).max, minimum: counts.map(&:last).min, container_seconds: seconds.round }
        end
    end
end
