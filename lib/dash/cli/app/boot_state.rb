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

    if names&.include?(Dash::Commands::App::ACTIVE_CONTAINERS_UNREADABLE)
      raise Dash::Cli::BootError, "Could not list the running containers of #{role}, not booting it"
    end

    @clashes = { 1 => clash.presence }.merge(clashes.each.with_index(2).to_h { |id, replica| [ replica, id.presence ] })
    @running = running_by_replica(running.presence, names&.lines&.map(&:strip)&.reject(&:empty?))
  end

  # How many replicas this boot starts: the slots running now, never fewer than min (so a
  # crash cannot shrink the role below its floor) nor more than max.
  def count
    role.replicas.clamp(running_count)
  end

  def replicas
    (1..count).to_a
  end

  def running_count
    @running.size
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
    # Every slot's version comes out of its container's name. Slot 1's own `--latest` read
    # wins for slot 1 (it prefers the latest image, as it always has), unless it is really
    # another slot's whole name: on a role that was scalable and no longer is, `--latest`
    # over the role labels can return a leftover slot's container.
    def running_by_replica(slot_one, names)
      by_replica = Array(names).reverse.to_h { |name| [ role.replica_from_name(name), role.version_from_name(name) ] }.except(nil)

      if slot_one && !foreign?(slot_one)
        by_replica[1] = slot_one
      end

      by_replica
    end

    def foreign?(version)
      (owner = role.replica_from_name(version)) && owner != 1
    end
end
