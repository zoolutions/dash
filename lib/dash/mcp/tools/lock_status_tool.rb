class Dash::Mcp::Tools::LockStatusTool < Dash::Mcp::BaseTool
  tool_name "lock_status"
  title "Deploy lock"
  description "Whether this destination's deploy lock is held, by whom, since when, at which version and with what message."
  input_schema properties: {}, additionalProperties: false

  def self.call(server_context:)
    answer(server_context) do
      primary = DASH.config.primary_host
      raise ArgumentError, "The deploy lock lives on the primary host #{primary}, outside this server's --hosts" unless DASH.hosts.include?(primary)

      Dash::Diagnostics::Lock.new(host: primary).to_h
    end
  end
end
