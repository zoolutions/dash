# What one scaled role looks like right now: how many of its containers run, which members
# are started, which hosts did not answer, or the provider error when its pool could not be
# read. One `docker ps` per host through Dash::Diagnostics::Scale, so one unreachable host
# makes the role hold instead of failing the tick.
#
# A host that does not answer is either a started member (the controller may replace it
# after `scale.boot_timeout`) or a baseline host (never touched: the role holds).
class Dash::Autoscale::Observation
  attr_reader :role, :current, :pool, :pool_error, :unreadable_baseline, :unreachable_members

  def self.take(role)
    status = Dash::Diagnostics::Scale.new(roles: [ role ]).to_h[:roles].first
    return new(role: role, pool_error: status[:error]) if status[:error]

    unread = status[:unread].to_h { |host| [ host[:host], host[:error] ] }
    baseline = unread.slice(*role.baseline_hosts)

    new(role: role, current: status[:total], pool: role.members, unreadable_baseline: baseline,
      unreachable_members: unread.except(*baseline.keys))
  end

  # `pool` is every member of the role, whatever its state.
  def initialize(role:, current: nil, pool: [], pool_error: nil, unreadable_baseline: {}, unreachable_members: {})
    @role, @current, @pool, @pool_error = role, current, pool, pool_error
    @unreadable_baseline, @unreachable_members = unreadable_baseline, unreachable_members
  end

  # The started members.
  def members
    pool.select(&:started?)
  end

  def member_hosts
    members.map(&:host)
  end

  # Every host of the role that did not answer.
  def unread_hosts
    unreadable_baseline.keys + unreachable_members.keys
  end
end
