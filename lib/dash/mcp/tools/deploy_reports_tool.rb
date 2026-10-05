class Dash::Mcp::Tools::DeployReportsTool < Dash::Mcp::BaseTool
  tool_name "deploy_reports"
  title "Deploy reports"
  description "The saved deploy reports for this destination, most recent first: command, status, runtime, per-phase timings and advice. Local, no SSH."
  input_schema properties: { last: { type: "integer", minimum: 1, maximum: Dash::Diagnostics::Reports::MAX, description: "How many reports (default 1)" } }, additionalProperties: false

  def self.call(server_context:, last: 1)
    answer(server_context) { Dash::Diagnostics::Reports.new(last: last).to_h }
  end
end
