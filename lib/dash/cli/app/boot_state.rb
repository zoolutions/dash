# What one host said about a role before a boot starts anything, parsed out of the single
# Commands::App#boot_states capture: which slots already hold the version being deployed,
# which version each slot runs now, and so how many replicas to boot.
#
# The replica count is never stored. It is the number of slots with a running container,
# kept within the role's bounds, so `dash scale set` changes it and a deploy reads it back.
class Dash::Cli::App::BootState
  attr_reader :role

  def initialize(role, output)
    @role = role

    clash, running, names, *clashes = Dash::Commands::App.split_states(output).map(&:strip)

    @clashes = { 1 => clash.presence }.merge(clashes.each.with_index(2).to_h { |id, replica| [ replica, id.presence ] })
    @running = running_by_replica(running.presence, names&.lines&.map(&:strip)&.reject(&:empty?))
  end

  # How many replicas this boot starts: the slots running now, never fewer than min (so a
  # crash cannot shrink the role below its floor) nor more than max.
  def count
    role.replicas.clamp(@running.size)
  end

  def replicas
    (1..count).to_a
  end

  def clashing?(replica)
    @clashes[replica].present?
  end

  def running_version(replica)
    @running[replica]
  end

  # Slots running above the count being booted - a lowered max, or a role whose
  # `replicas` key went away. Their containers are stopped with the old version.
  def surplus_replicas
    @running.keys.select { |replica| replica > count }.sort
  end

  private
    # Without the names (an older answer shape), slot 1's `--latest` read is all there is.
    # With them, every slot's version comes out of its container's name, and slot 1's read
    # is kept only when it really is slot 1's: on a role that was scalable and no longer
    # is, `--latest` over the role labels can return another slot's container.
    def running_by_replica(slot_one, names)
      return slot_one ? { 1 => slot_one } : {} if names.nil?

      by_replica = names.reverse.to_h { |name| [ role.replica_from_name(name), role.version_from_name(name) ] }.except(nil)
      by_replica[1] = slot_one if slot_one && names.include?(role.replica_name(1, slot_one))
      by_replica
    end
end
