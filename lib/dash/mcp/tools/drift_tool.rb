class Dash::Mcp::Tools::DriftTool < Dash::Mcp::BaseTool
  tool_name "drift"
  title "Drift"
  description <<~DESC
    Whether the proxy pool is consistent with what runs: compares containers with dash-proxy and load balancer targets.
    Each mismatch has a code: proxy_target_not_running, running_not_targeted, loadbalancer_target_missing,
    loadbalancer_target_extra, version_mismatch, multiple_running_versions, member_not_targeted (a started pool member
    the load balancer does not forward to), member_orphan (a started pool member running nothing of its role).
    Version codes are skipped while the deploy lock is held.
  DESC
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::Drift.take.to_h }
  end
end
