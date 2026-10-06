class Dash::Mcp::Tools::ContainerStatsTool < Dash::Mcp::BaseTool
  tool_name "container_stats"
  title "Container resource usage"
  description <<~DESC
    CPU %, memory and its limit, network and block I/O, and PIDs of every running container of this service per app host,
    with role, replica slot and version - and under `accessories`, the same for each accessory's container on its own hosts.
    A point-in-time sample: docker stats measures over about a second per host.
    No argument reaches the command; hosts and roles only choose which configured hosts are asked.
  DESC
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::ContainerStats.new.to_h }
  end
end
