# `dash autoscale history` and the MCP `autoscale_decisions` tool: the tail of the
# controller's decision log on the primary host, oldest first - of one role, or of all.
# Each entry is what the controller decided, why, and every input it used.
class Dash::Diagnostics::AutoscaleDecisions < Dash::Diagnostics::Base
  DEFAULT_LINES = 50

  def initialize(role: nil, lines: DEFAULT_LINES)
    @role, @lines = role, Dash::Diagnostics::Lines.bounded(lines)
  end

  private
    def snapshot
      per_host([ Dash::Autoscale::StateStore.host ]) do |backend, _host|
        { decisions: Dash::Autoscale::StateStore.new(backend).decisions(lines: @lines, role: @role) }
      end.first
    end
end
