class Dash::Mcp::Tools::PoolMembersTool < Dash::Mcp::BaseTool
  tool_name "pool_members"
  title "Pool members"
  description <<~DESC
    The autoscale pool of every scaled role: its provider, members mode (power or create), host bounds and baseline
    hosts, and per member its provider id, host, state (started, stopped, maintenance, error), labels, whether the
    provider vouched for it (verified false: taken from --hosts while the provider was down), the versions a started
    member runs, and orphan (started but running nothing of the role). A provider that does not answer is the role's error.
  DESC
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::Pool.new.to_h }
  end
end
