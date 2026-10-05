class Dash::Mcp::Tools::LogsTool < Dash::Mcp::BaseTool
  tool_name "logs"
  title "Container logs"
  description <<~DESC
    The tail of a role's containers on its hosts, every replica slot. Off unless the server was started with --allow-logs
    (or DASH_MCP_ALLOW_LOGS=true): logs can carry personal data. grep is a plain substring match.
  DESC
  input_schema properties: {
    role: { type: "string", description: "The role (default: the primary role)" },
    hosts: SCOPE[:hosts],
    lines: { type: "integer", minimum: 1, maximum: Dash::Diagnostics::Lines::MAX, description: "Lines per container (default 100)" },
    since: { type: "string", description: "A duration like 15m or 1h30m, or a timestamp like 2026-10-05T10:00:00Z" },
    grep: { type: "string", maxLength: Dash::Diagnostics::Logs::MAX_GREP_LENGTH, description: "Only lines containing this text" }
  }, additionalProperties: false

  REFUSED = "The logs tool is off: container logs can carry personal data. Restart `dash mcp` with --allow-logs (or DASH_MCP_ALLOW_LOGS=true) to enable it."

  def self.call(server_context:, role: nil, hosts: nil, lines: 100, since: nil, grep: nil)
    return error_response(REFUSED) unless server_context.fetch(:session).allow_logs?

    answer(server_context, hosts: hosts) do
      Dash::Diagnostics::Logs.new(role: scoped_role(role), lines: lines, since: since, grep: grep).to_h
    end
  end

  def self.scoped_role(name)
    return DASH.primary_role unless name

    DASH.roles.find { |role| role.name == name } || raise(ArgumentError, "No role #{name} within this server's scope (#{DASH.roles.map(&:name).join(",")})")
  end
end
