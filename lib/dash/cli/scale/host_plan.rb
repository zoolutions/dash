# How `dash scale set` reaches a container count on a scaled role, across hosts. Pure: it is
# handed the role's baseline hosts, its started members (in the order they would leave
# last-first), the target and both bounds, and says how many
# members join, which leave, and how many containers each host ends with.
#
# Hosts are kept as few as the count allows, never below scale min or the baseline (so
# scale min joins members too). Every
# host gets replicas min; the rest fills the baseline first, then members in order - so a
# scale-out fills the hosts it has before a member joins, and a scale-in empties members
# down to min, then lets them leave, before the baseline gives anything up.
class Dash::Cli::Scale::HostPlan
  attr_reader :joins, :leaving, :counts, :join_counts

  # [ slots to add, slots to remove ] to take a host from `slots` to `count` containers:
  # the lowest free slots in, the highest out.
  def self.slot_changes(slots, count)
    slots = slots.sort

    if count > slots.size
      [ ((1..count + slots.size).to_a - slots).first(count - slots.size), [] ]
    else
      [ [], slots.reverse.first(slots.size - count) ]
    end
  end

  def initialize(baseline:, members:, target:, replicas_min:, replicas_max:, hosts_min:, hosts_max:)
    @min, @max = replicas_min, replicas_max
    current = baseline + members
    hosts = host_count(baseline.size, target, hosts_min)

    raise ArgumentError, "#{target} containers need #{hosts} hosts, scale max is #{hosts_max}" if hosts > hosts_max
    if hosts * @min > target || hosts * @max < target
      raise ArgumentError, "#{target} containers cannot be split over #{hosts} hosts with #{@min} to #{@max} per host"
    end

    @joins = [ hosts - current.size, 0 ].max
    @leaving = members.last([ current.size - hosts, 0 ].max)

    kept = current - @leaving
    spread = spread(target, kept.size + @joins)
    @counts = kept.zip(spread).to_h
    @join_counts = spread.drop(kept.size)
  end

  private
    # As few hosts as the count fits on, never below the baseline or scale min - which is
    # hosts kept running, so it joins members as well as keeping them.
    def host_count(baseline, target, hosts_min)
      [ (target.to_f / @max).ceil, hosts_min, baseline ].max
    end

    # Each host min, then the rest to the earliest hosts up to max.
    def spread(target, hosts)
      counts = Array.new(hosts, @min)
      remaining = target - (hosts * @min)

      counts.map do |count|
        extra = [ remaining, @max - count ].min
        remaining -= extra
        count + extra
      end
    end
end
