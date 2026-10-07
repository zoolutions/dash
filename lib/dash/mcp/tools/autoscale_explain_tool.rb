class Dash::Mcp::Tools::AutoscaleExplainTool < Dash::Mcp::BaseTool
  tool_name "autoscale_explain"
  title "Autoscale explain"
  description <<~DESC
    One live evaluation of a scaled role by the autoscale policy, as the controller's next tick would make it, without acting:
    the action (scale_out, scale_in, replace_member, hold), the container counts from and to, the reason codes (schedule_floor,
    at_min, at_max, at_target, cooldown, warming_up, paused, lock_busy, member_unreachable, host_unreachable, pool_unreadable,
    action_failed), when a hold can next change (eligible_at), and every input: running count, floor, bounds, active schedule
    windows, cooldowns, last scale times, warming and unreachable members, pause. controlled is false for a role without a
    schedule, which the controller leaves alone.
  DESC
  input_schema properties: { role: { type: "string", description: "The scaled role" } }, required: [ "role" ], additionalProperties: false

  def self.call(server_context:, role:)
    answer(server_context) do
      ensure_state_host_in_scope
      Dash::Diagnostics::AutoscaleExplain.new(role: scoped_role(role)).to_h
    end
  end

  def self.scoped_role(name)
    role = DASH.config.role(name) || raise(ArgumentError, "No role named #{name} (#{DASH.config.roles.map(&:name).join(",")})")
    raise ArgumentError, "#{name} is outside this server's --roles and --hosts" unless roles_in_scope.include?(role)

    role
  end

  # The roles within --roles, and with a baseline host within --hosts - from deploy.yml,
  # never DASH.roles: that would ask the provider for the pool, and a pool that does not
  # answer is an answer explain should give.
  def self.roles_in_scope
    roles = DASH.specific_roles || DASH.config.roles
    DASH.specific_hosts ? roles.select { |role| (role.baseline_hosts & DASH.specific_hosts).any? } : roles
  end

  # nil when nothing narrows the server: every role's decisions.
  def self.role_names_in_scope
    roles_in_scope.map(&:name) if DASH.specific_roles || DASH.specific_hosts
  end

  # The controller's state host (Dash::Autoscale::StateStore.host) must be within the
  # server's --hosts, or the hosts of its --roles (as lock_status asks) - when it is one of
  # the app's hosts. The ceiling is over those: an `autoscale.controller` ops host that is
  # none of them is outside its reach, and always answers. Baseline hosts only, never the
  # pool, which a scope check must not ask.
  def self.ensure_state_host_in_scope
    host = Dash::Autoscale::StateStore.host
    return unless (DASH.config.roles.flat_map(&:baseline_hosts) + DASH.config.accessories.flat_map(&:hosts)).include?(host)

    hosts = DASH.specific_hosts || DASH.specific_roles&.flat_map(&:baseline_hosts)

    raise ArgumentError, "The autoscale state lives on #{host}, outside this server's --hosts and --roles" if hosts && !hosts.include?(host)
  end
end
