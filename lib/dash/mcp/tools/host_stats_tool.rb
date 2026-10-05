class Dash::Mcp::Tools::HostStatsTool < Dash::Mcp::BaseTool
  tool_name "host_stats"
  title "Host resource usage"
  description <<~DESC
    Per host: load average (1/5/15 minutes, and per CPU), CPU count, memory and swap, disk for / and for Docker's data root,
    and uptime. A point-in-time read of /proc and df. No argument reaches the command; hosts and roles only choose which
    configured hosts are asked.
  DESC
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::HostStats.new.to_h }
  end
end
