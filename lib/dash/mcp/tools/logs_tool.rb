class Dash::Mcp::Tools::LogsTool < Dash::Mcp::BaseTool
  tool_name "logs"
  title "Container logs"
  description <<~DESC
    The tail of a role's containers on its hosts (every replica slot), or of an accessory's. Off unless the server was started with --allow-logs
    (or DASH_MCP_ALLOW_LOGS=true): logs can carry personal data. grep is a plain substring match.
  DESC
  input_schema properties: {
    role: { type: "string", description: "The role (default: the primary role)" },
    accessory: { type: "string", description: "An accessory instead of a role (e.g. the database)" },
    hosts: SCOPE[:hosts],
    lines: { type: "integer", minimum: 1, maximum: Dash::Diagnostics::Lines::MAX, description: "Lines per container (default 100)" },
    since: { type: "string", description: "A duration like 15m or 1h30m, or a timestamp like 2026-10-05T10:00:00Z" },
    grep: { type: "string", maxLength: Dash::Diagnostics::Logs::MAX_GREP_LENGTH, description: "Only lines containing this text" }
  }, additionalProperties: false

  REFUSED = "The logs tool is off: container logs can carry personal data. Restart `dash mcp` with --allow-logs (or DASH_MCP_ALLOW_LOGS=true) to enable it."

  def self.call(server_context:, role: nil, accessory: nil, hosts: nil, lines: 100, since: nil, grep: nil)
    return error_response(REFUSED) unless server_context.fetch(:session).allow_logs?
    return error_response("Pass a role or an accessory, not both") if role && accessory

    answer(server_context, hosts: hosts) do
      source = accessory ? { accessory: scoped_accessory(accessory) } : { role: scoped_role(role) }
      Dash::Diagnostics::Logs.new(**source, lines: lines, since: since, grep: grep, redactor: server_context.fetch(:session).redactor).to_h
    end
  end

  def self.scoped_accessory(name)
    accessory = DASH.config.accessory(name) || raise(ArgumentError, "No accessory #{name} (#{DASH.accessory_names.join(",")})")
    raise ArgumentError, "Accessory #{name} runs on no host within this server's scope" if (accessory.hosts & DASH.accessory_hosts).empty?

    accessory
  end

  def self.scoped_role(name)
    return DASH.primary_role unless name

    DASH.roles.find { |role| role.name == name } || raise(ArgumentError, "No role #{name} within this server's scope (#{DASH.roles.map(&:name).join(",")})")
  end
end
