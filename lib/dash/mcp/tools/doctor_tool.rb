class Dash::Mcp::Tools::DoctorTool < Dash::Mcp::BaseTool
  tool_name "doctor"
  title "Doctor"
  description <<~DESC
    dash doctor's readiness checks as {check, target, status, detail}: SSH, Docker, proxy image and version, ports, DNS,
    certificates, readiness gates and drift. The registry check is skipped: it runs docker login on each host.
  DESC
  input_schema properties: SCOPE, additionalProperties: false

  def self.call(server_context:, hosts: nil, roles: nil)
    answer(server_context, hosts: hosts, roles: roles) { Dash::Diagnostics::Doctor.new(registry: false).to_h }
  end
end
