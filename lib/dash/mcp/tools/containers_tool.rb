class Dash::Mcp::Tools::ContainersTool < Dash::Mcp::BaseTool
  tool_name "containers"
  title "Containers"
  description "Every container of this service per app host: role, replica slot, version, state, health, image and creation time."
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::Containers.new.to_h }
  end
end
