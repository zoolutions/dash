class Dash::Mcp::Tools::ProxyServicesTool < Dash::Mcp::BaseTool
  tool_name "proxy_services"
  title "Proxy services"
  description "What dash-proxy routes for this deploy on each proxy host (domains, targets, state), and the load balancer's routes when load balancing is on."
  input_schema properties: SCOPE.slice(:hosts), additionalProperties: false

  def self.call(server_context:, hosts: nil)
    answer(server_context, hosts: hosts) { Dash::Diagnostics::ProxyServices.new.to_h }
  end
end
