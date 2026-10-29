class Dash::Mcp::Tools::SignalSampleTool < Dash::Mcp::BaseTool
  tool_name "signal_sample"
  title "Signal sample"
  description <<~DESC
    One live sample of a scaled role's autoscale signal (scale.signal: sidekiq or pgbus queue age in seconds, or a Prometheus
    query) and of each of its saturation guards (scale.hold_when), read from the machine dash mcp runs on, each with its latency:
    the source, value, time and error of the signal, where it sits against the role's band (above, inside, below) and the band
    itself (up.above, up.for, down.below, down.for); per guard its index, source, bound, value, error and whether it is holding
    a scale-out. The fields match the signal and guards inputs of the controller's decisions, so a sample compares directly
    with autoscale_explain and autoscale_decisions. Reads only. configured is false for a role without a signal.
  DESC
  input_schema properties: { role: { type: "string", description: "The scaled role" } }, required: [ "role" ], additionalProperties: false

  def self.call(server_context:, role:)
    answer(server_context) do
      Dash::Diagnostics::AutoscaleSignal.new(role: Dash::Mcp::Tools::AutoscaleExplainTool.scoped_role(role)).to_h
    end
  end
end
