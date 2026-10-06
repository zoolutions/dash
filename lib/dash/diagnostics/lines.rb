# The one bound on how many lines a diagnostic reads per host (audit, logs), so a large
# fleet or a chatty app cannot flood whoever asked - above all an agent's context.
module Dash::Diagnostics::Lines
  MAX = 500

  def self.bounded(lines)
    count = Integer(lines.to_s, 10)
    raise ArgumentError, "lines must be between 1 and #{MAX}, got #{lines}" unless count.between?(1, MAX)

    count
  rescue TypeError
    raise ArgumentError, "lines must be a number, got #{lines.inspect}"
  end
end
