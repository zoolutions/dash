# Where `dash scale set` adds or removes containers to reach a total. Pure: it is handed the
# slots running on each host and returns the slots to add and remove per host.
#
# Adds go to the host with the fewest replicas, in its lowest free slot; removals come from
# the host with the most, highest slot first. Ties go to the earlier host for adds and the
# later host for removals, so repeated scaling out and in keeps the same hosts fuller.
class Dash::Cli::Scale::Placement
  attr_reader :additions, :removals

  def initialize(running:, target:, max:)
    @slots = running.transform_values { |slots| slots.sort }
    @max = max
    @additions = Hash.new { |hash, host| hash[host] = [] }
    @removals = Hash.new { |hash, host| hash[host] = [] }

    plan(target)

    @additions = @additions.to_h
    @removals = @removals.to_h
  end

  private
    # A host above max (max was lowered since it scaled) sheds its surplus first: the next
    # deploy would clamp it anyway, and the count asked for would quietly not hold.
    def plan(target)
      @slots.each_key do |host|
        remove_from(host) while @slots[host].size > @max
      end

      total = @slots.values.sum(&:size)

      (target - total).times { add_one } if target > total
      (total - target).times { remove_one } if target < total
    end

    def add_one
      host = @slots.keys.select { |candidate| @slots[candidate].size < @max }.min_by { |candidate| @slots[candidate].size }
      slot = ((1..@max).to_a - @slots[host]).first

      @slots[host] = (@slots[host] + [ slot ]).sort
      @additions[host] << slot
    end

    def remove_one
      remove_from @slots.keys.reverse.max_by { |candidate| @slots[candidate].size }
    end

    def remove_from(host)
      slot = @slots[host].max

      @slots[host] = @slots[host] - [ slot ]
      @removals[host] << slot
    end
end
