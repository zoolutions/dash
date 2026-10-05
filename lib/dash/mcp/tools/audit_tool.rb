class Dash::Mcp::Tools::AuditTool < Dash::Mcp::BaseTool
  tool_name "audit"
  title "Audit log"
  description "The last lines of this deploy's audit log on each host, parsed into recorded_at, performer, tags and message."
  input_schema properties: SCOPE.slice(:hosts).merge(lines: { type: "integer", minimum: 1, maximum: Dash::Diagnostics::Lines::MAX, description: "Lines per host (default 50)" }),
    additionalProperties: false

  def self.call(server_context:, hosts: nil, lines: 50)
    answer(server_context, hosts: hosts) { Dash::Diagnostics::Audit.new(lines: lines).to_h }
  end
end
