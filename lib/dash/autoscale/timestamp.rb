require "time"

# The times the controller's state files hold: ISO 8601 in UTC. A value that does not parse
# reads as nil, because a hand-edited or half-written file must never stop the controller.
module Dash::Autoscale::Timestamp
  def self.parse(value)
    Time.iso8601(value).utc if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def self.dump(time)
    time&.utc&.iso8601
  end
end
