class Dash::Mcp::Tools::ControllerStatusTool < Dash::Mcp::BaseTool
  tool_name "controller_status"
  title "Autoscale controller"
  description <<~DESC
    Whether the autoscale controller (dash autoscale run) is running: its heartbeat - controller id, host, pid, dash version,
    mode, interval, last tick and its age - read as running, stale (no tick for three intervals) or stopped; null when none ever ran.
    Also the roles with a schedule it controls, and the pauses in force (role, until, by whom).
  DESC
  input_schema properties: {}, additionalProperties: false

  def self.call(server_context:)
    answer(server_context) do
      Dash::Mcp::Tools::AutoscaleExplainTool.ensure_state_host_in_scope

      Dash::Diagnostics::ControllerStatus.new.to_h
    end
  end
end
