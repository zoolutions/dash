class Dash::Mcp::Tools::ConfigTool < Dash::Mcp::BaseTool
  tool_name "config"
  title "Configuration"
  description "The effective deploy configuration (redacted) and its topology: which hosts each role runs on, which roles are proxied, the proxy hosts and the load balancer. Local, no SSH."
  input_schema properties: {}, additionalProperties: false

  def self.call(server_context:)
    answer(server_context) { Dash::Diagnostics::Config.new.to_h }
  end
end
