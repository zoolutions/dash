class Dash::Mcp::Tools::AutoscaleDecisionsTool < Dash::Mcp::BaseTool
  tool_name "autoscale_decisions"
  title "Autoscale decisions"
  description <<~DESC
    The autoscale controller's decision log, oldest first: each time a role's action or reasons changed, and every scale action,
    with the container counts, reason codes, error (lock_busy, action_failed) and every input the policy used.
  DESC
  input_schema properties: {
    role: { type: "string", description: "Only this role's decisions" },
    lines: { type: "integer", minimum: 1, maximum: Dash::Diagnostics::Lines::MAX, description: "How many decisions (default 50)" }
  }, additionalProperties: false

  def self.call(server_context:, role: nil, lines: Dash::Diagnostics::AutoscaleDecisions::DEFAULT_LINES)
    answer(server_context) do
      raise ArgumentError, "No role named #{role} (#{DASH.config.roles.map(&:name).join(",")})" if role && !DASH.config.role(role)
      Dash::Mcp::Tools::AutoscaleExplainTool.ensure_state_host_in_scope

      Dash::Diagnostics::AutoscaleDecisions.new(role: role, lines: lines).to_h
    end
  end
end
