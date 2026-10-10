# `dash autoscale history` and the MCP `autoscale_decisions` tool: the tail of the
# controller's decision log on the state host, oldest first - of some roles, or of all.
# Each entry is what the controller decided, why, and every input it used.
class Dash::Diagnostics::AutoscaleDecisions < Dash::Diagnostics::Base
  DEFAULT_LINES = 50

  # `roles`: role names, or nil for every role.
  def initialize(roles: nil, lines: DEFAULT_LINES)
    @roles, @lines = roles, Dash::Diagnostics::Lines.bounded(lines)
  end

  private
    def snapshot
      per_host([ Dash::Autoscale::StateStore.host ]) do |backend, _host|
        { decisions: Dash::Autoscale::StateStore.new(backend).decisions(lines: @lines, roles: @roles) }
      end.first
    end
end
