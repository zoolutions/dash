# What the controller should do with one scaled role, now. Pure: every input is handed in -
# the clock, the running count, the history of past actions, pauses, which members are
# warming up or unreachable - and `decide` returns one Dash::Autoscale::Decision. No SSH, no
# provider call, no clock of its own.
#
# The target is the floor: scale min × replicas min, raised by any active schedule window,
# never above scale max × replicas max. Below it the role scales out straight to it; above
# it the role scales in by `scale.step` at most, once per `cooldown.down`, never while a
# member warms up. Counts are containers; Dash::Cli::Scale::HostPlan turns them into hosts.
class Dash::Autoscale::Policy
  attr_reader :role, :now, :current

  # history:             { last_scale_out_at:, last_scale_in_at: }
  # paused_until:        nil, a Time, or :indefinite
  # warming:             { member host => joined at }
  # unreachable:         { member host => unreachable since }
  # unreadable_baseline: { baseline host => error }
  # pool_error:          the provider's error when the pool could not be read
  def initialize(role:, now:, time_zone:, current:, history: {}, paused_until: nil, warming: {}, unreachable: {}, unreadable_baseline: {}, pool_error: nil)
    @role, @scale = role, role.scale
    @now, @time_zone, @current = now, time_zone, current
    @history, @paused_until, @warming, @unreachable = history, paused_until, warming, unreachable
    @unreadable_baseline, @pool_error = unreadable_baseline, pool_error
  end

  def decide
    return hold("pool_unreadable", error: @pool_error) if @pool_error
    return hold("paused", eligible_at: (@paused_until unless @paused_until == :indefinite)) if paused?
    return hold("host_unreachable", error: @unreadable_baseline.map { |host, error| "#{host}: #{error}" }.join("; ")) if @unreadable_baseline.any?
    return unreachable_member if @unreachable.any?

    if current < floor
      decision("scale_out", to: floor, reasons: floor_reasons)
    elsif current > floor
      scale_in
    else
      hold("at_target")
    end
  end

  def floor
    @floor ||= [ [ @scale.min_count, *active_windows.map { |window| window[:min] } ].max, @scale.max_count ].min
  end

  private
    def paused?
      @paused_until == :indefinite || (@paused_until && now < @paused_until)
    end

    # One member per tick, the longest unreachable first, once it has had boot_timeout to
    # answer and is past its warmup.
    def unreachable_member
      eligible_at = @unreachable.to_h { |host, since| [ host, [ since + @scale.boot_timeout, warmup_ends_at(host) ].compact.max ] }
      ready = eligible_at.select { |_, at| now >= at }.keys

      if ready.any?
        decision("replace_member", to: current, reasons: [ "member_unreachable" ], replace: ready.min_by { |host| @unreachable[host] })
      else
        hold("member_unreachable", eligible_at: eligible_at.values.min)
      end
    end

    def scale_in
      if warming_hosts.any?
        hold("warming_up", eligible_at: warming_hosts.map { |host| warmup_ends_at(host) }.max)
      elsif last_action_at && now < last_action_at + @scale.cooldown_down
        hold("cooldown", eligible_at: last_action_at + @scale.cooldown_down)
      else
        decision("scale_in", to: step_target, reasons: floor_reasons)
      end
    end

    # A step down, never below the floor, landing on a count the hosts can split: the
    # nearest one above, else the nearest one below.
    def step_target
      target = [ floor, current - @scale.step ].max

      (target...current).find { |count| @scale.splittable?(count) } ||
        target.downto(floor).find { |count| @scale.splittable?(count) } || floor
    end

    def floor_reasons
      reasons = [ active_windows.any? { |window| window[:min] > @scale.min_count } ? "schedule_floor" : "at_min" ]
      reasons << "at_max" if active_windows.any? { |window| window[:min] > @scale.max_count }
      reasons
    end

    def active_windows
      @active_windows ||= begin
        local = now.in_time_zone(@time_zone)

        @scale.schedule.filter_map do |window|
          if (started_at = window.started_at(local))
            window.to_h.merge(started_at: started_at.utc, ends_at: (started_at + window.duration).utc)
          end
        end
      end
    end

    def warming_hosts
      @warming_hosts ||= @warming.keys.select { |host| now < warmup_ends_at(host) }
    end

    def warmup_ends_at(host)
      @warming[host]&.+(@scale.warmup)
    end

    def last_action_at
      @history.values_at(:last_scale_out_at, :last_scale_in_at).compact.max
    end

    def hold(reason, eligible_at: nil, error: nil)
      decision("hold", to: current, reasons: [ reason ], eligible_at: eligible_at, error: error)
    end

    def decision(action, to:, reasons:, eligible_at: nil, error: nil, **extra)
      Dash::Autoscale::Decision.new(role: role.name.to_s, action: action, from: current, to: to, reasons: reasons,
        inputs: inputs.merge(extra), eligible_at: eligible_at, at: now, error: error)
    end

    def inputs
      {
        current: current, floor: floor, min_count: @scale.min_count, max_count: @scale.max_count, step: @scale.step,
        cooldown_up: @scale.cooldown_up, cooldown_down: @scale.cooldown_down, warmup: @scale.warmup, boot_timeout: @scale.boot_timeout,
        windows: active_windows, last_scale_out_at: @history[:last_scale_out_at], last_scale_in_at: @history[:last_scale_in_at],
        warming: warming_hosts, unreachable: @unreachable, unreadable_baseline: @unreadable_baseline, paused_until: @paused_until
      }
    end
end
