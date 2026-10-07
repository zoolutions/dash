# The controller's heartbeat read as a lease: alive while its last tick is within three of
# its own intervals and it has not stopped. A second controller refuses to start while
# another one's lease is alive, and a running one stops when the heartbeat names another
# controller. Convergent, not a hard mutex - the deploy lock still serializes every scale
# action.
class Dash::Autoscale::Lease
  STALE_AFTER_INTERVALS = 3

  attr_reader :heartbeat

  def initialize(heartbeat, now:)
    @heartbeat = heartbeat.is_a?(Hash) ? heartbeat : {}
    @now = now
  end

  def controller_id
    heartbeat["controller_id"]
  end

  def last_tick_at
    Dash::Autoscale::Timestamp.parse(heartbeat["last_tick_at"])
  end

  def interval
    Integer(heartbeat["interval"].to_s, 10)
  rescue ArgumentError
    Dash::Configuration::Autoscale::DEFAULT_INTERVAL
  end

  # Whole seconds since the last tick, nil without one.
  def age
    (@now - last_tick_at).floor if last_tick_at
  end

  def stopped?
    heartbeat["stopped_at"].present?
  end

  def alive?
    !stopped? && !age.nil? && age <= STALE_AFTER_INTERVALS * interval
  end

  def held_by_another?(id)
    alive? && controller_id != id
  end

  def describe
    tick = age ? "last tick #{age}s ago" : "no tick yet"
    "controller #{controller_id} on #{heartbeat["hostname"]} (pid #{heartbeat["pid"]}, dash #{heartbeat["version"]}), #{tick}"
  end
end
