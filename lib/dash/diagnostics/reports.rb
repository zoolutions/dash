# The deploy reports saved under `.dash/reports` for this destination, most recent first.
# Local and read-only: no SSH at all.
class Dash::Diagnostics::Reports < Dash::Diagnostics::Base
  MAX = 20

  def initialize(last: 1, directory: Dash::ProjectDirectory.join("reports"))
    @last = Integer(last.to_s, 10)
    raise ArgumentError, "last must be between 1 and #{MAX}, got #{last}" unless @last.between?(1, MAX)

    @directory = directory
  end

  private
    def snapshot
      { reports: Dash::Report::History.new(@directory, destination: DASH.config.destination).recent(@last) }
    end
end
