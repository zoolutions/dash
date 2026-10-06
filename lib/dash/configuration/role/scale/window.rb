# One `scale.schedule` entry: from every minute `cron` matches, for `duration` seconds, the
# role runs at least `min` containers. Times are handed in already in `autoscale.timezone`,
# so the cron is wall-clock there while the duration is real seconds (a window that spans a
# DST change still lasts `for`).
class Dash::Configuration::Role::Scale::Window
  attr_reader :cron, :duration, :min

  def initialize(cron:, duration:, min:)
    @cron = cron
    @duration = duration
    @min = min
  end

  def active_at?(now)
    !started_at(now).nil?
  end

  # The latest minute in (now - duration, now] the cron matches, scanned backwards: at most
  # 10 080 steps for the 7-day limit.
  def started_at(now)
    earliest = now - duration
    minute = now.change(sec: 0)

    while minute > earliest
      return minute if cron.match?(minute)
      minute -= 60
    end
  end

  def ends_at(now)
    started_at(now)&.+(duration)
  end

  def to_h
    { cron: cron.to_s, for: duration, min: min }
  end
end
