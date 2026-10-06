class Dash::Mcp::Tools::ScaleStatusTool < Dash::Mcp::BaseTool
  tool_name "scale_status"
  title "Scale status"
  description "Per role: its replicas bounds (min, max per host), how many containers run in total, and each host's replica slots with version and docker status. Hosts that could not be read are listed under unread."
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::Scale.new.to_h }
  end
end
