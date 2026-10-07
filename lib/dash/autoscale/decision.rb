# What the controller decided for one scaled role on one tick: the action, the container
# count it goes from and to, the reason codes, and every input the policy used. The reason
# and action codes are stable - the decision log, the metrics and the MCP tools all use them.
#
# On a scale_out or scale_in the reasons name what set the target the role moves toward:
# `schedule_floor` (a window), `at_min` (scale min × replicas min), plus `at_max` when the
# target was capped. A scale_in step that stops short of the target still names the target.
Dash::Autoscale::Decision = Struct.new(:role, :action, :from, :to, :reasons, :inputs, :eligible_at, :at, :error, keyword_init: true) do
  def initialize(reasons: [], inputs: {}, **attributes)
    super
  end

  # Times as ISO 8601 in UTC, symbols as strings, all the way down - what JSON, the MCP
  # tools and the decision log carry.
  def self.json_safe(value)
    case value
    when Hash then value.to_h { |key, item| [ key, json_safe(item) ] }
    when Array then value.map { |item| json_safe(item) }
    when Time, ActiveSupport::TimeWithZone then value.utc.iso8601
    when Symbol then value.to_s
    when Exception then value.message
    else value
    end
  end

  def hold?
    action == "hold"
  end

  # The member a `replace_member` decision takes out.
  def member_host
    inputs[:replace]
  end

  def to_h
    Dash::Autoscale::Decision.json_safe(super)
  end

  # One log line: `payments: scale_out 4 -> 10 (schedule_floor: window "0 22 1,15 * *" min 10)`.
  def summary
    counts = case action
    when "hold" then "at #{from.nil? ? "?" : from}"
    when "replace_member" then member_host
    else "#{from} -> #{to}"
    end

    "#{role}: #{action} #{counts} (#{reasons.map { |reason| note(reason) }.join(", ")})"
  end

  private
    def note(reason)
      case reason
      when "schedule_floor"
        window = inputs[:windows].to_a.max_by { |candidate| candidate[:min] }
        window ? %(#{reason}: window "#{window[:cron]}" min #{window[:min]}) : reason
      when "cooldown", "warming_up", "member_unreachable", "paused"
        eligible_at ? "#{reason} until #{eligible_at.utc.iso8601}" : reason
      else
        error ? "#{reason}: #{error}" : reason
      end
    end
end

Dash::Autoscale::Decision::ACTIONS = %w[ scale_out scale_in replace_member hold ].freeze
Dash::Autoscale::Decision::REASONS = %w[
  schedule_floor at_min at_max at_target cooldown warming_up paused lock_busy
  member_unreachable host_unreachable pool_unreadable action_failed
].freeze
