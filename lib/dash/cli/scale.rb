# Changes how many containers of a role run, at runtime, at the version already running -
# no build and no deploy. The count is in containers across the role's hosts, like Heroku
# dynos, spread evenly within each host's `replicas` bounds. A later deploy keeps it,
# because a deploy boots as many replicas as are running.
#
# A role with `scale:` also spans hosts: when its hosts are full, pool members join (see
# Dash::Cli::Scale::Join), and they leave again before the baseline gives up a container
# (Dash::Cli::Scale::HostPlan).
class Dash::Cli::Scale < Dash::Cli::Base
  desc "set ROLE COUNT", "Run COUNT containers of ROLE across its hosts, within its replicas bounds (and scale bounds, joining or removing pool members)"
  option :keep_on_failure, type: :boolean, default: false, desc: "Leave a member that failed to join powered on, for debugging"
  def set(role_name, count)
    role = scalable_role(role_name)
    count = Integer(count, 10)
    ensure_within_bounds(role, count)

    modify(lock: true) do
      next scale_across_hosts(role, count) if role.scaled?

      running = running_replicas(role)
      placement = Dash::Cli::Scale::Placement.new(running: running.transform_values(&:keys), target: count, max: role.replicas.max)

      if placement.additions.empty? && placement.removals.empty?
        say "#{role} already runs #{count} containers", :magenta
      else
        scale_out(role, placement.additions, running, count) if placement.additions.any?
        scale_in(role, placement.removals, running, count) if placement.removals.any?
        say "#{role} now runs #{count} containers", :magenta
      end
    end
  end

  desc "status [ROLE]", "Show the containers of each role per host (or one role)"
  option :json, type: :boolean, default: false, desc: "Print the status as JSON"
  def status(role_name = nil)
    roles = role_name ? [ scalable_role(role_name) ] : DASH.config.roles
    scale = -> { Dash::Diagnostics::Scale.new(roles: roles).to_h }

    if options[:json]
      puts_json(&scale)
    else
      pre_connect_if_required
      scale.call[:roles].each { |role| print_status(role) }
    end
  end

  no_commands do
    # Run a sub-command on one host and role. Sub-commands read the run's scope from DASH,
    # not from their own --hosts/--roles once DASH is configured, so the scope is set here.
    def narrowed_to(host, role)
      hosts, roles = DASH.specific_hosts, DASH.specific_roles&.map(&:name)
      DASH.specific_hosts = [ host ]
      DASH.specific_roles = [ role.name ]
      yield
    ensure
      DASH.specific_roles = roles
      DASH.specific_hosts = hosts
    end

    def invoke_narrowed(command, cli_class, **command_options)
      invoke command, [], options.except("keep_on_failure").merge(command_options)
      reset_invocation(cli_class)
    end

    def on_hosts(hosts, &block)
      on(hosts, &block)
    end

    def report(message, color = nil)
      say message, color
    end

    def deploy_loadbalancer(except: nil)
      targets = DASH.loadbalancer_config.target_hosts - Array(except)

      on(DASH.config.proxy.effective_loadbalancer) do |host|
        Dash::Cli::Proxy::LoadbalancerDeploy.new(host, self, targets: targets).run
      end
    end
  end

  private
    def scalable_role(role_name)
      DASH.config.role(role_name) || raise(ArgumentError, "No role named #{role_name}, expected one of #{DASH.config.roles.map(&:name).join(", ")}")
    end

    def ensure_within_bounds(role, count)
      return ensure_within_scale_bounds(role, count) if role.scaled?

      hosts = role.hosts.size
      bounds = (hosts * role.replicas.min)..(hosts * role.replicas.max)

      unless bounds.cover?(count)
        raise ArgumentError, "#{role} runs #{bounds.min} to #{bounds.max} containers on its #{hosts} #{"host".pluralize(hosts)} " \
          "(replicas min #{role.replicas.min}, max #{role.replicas.max} per host), not #{count}"
      end
    end

    def ensure_within_scale_bounds(role, count)
      scale, replicas = role.scale, role.replicas
      bounds = (scale.min * replicas.min)..(scale.max * replicas.max)

      unless bounds.cover?(count)
        raise ArgumentError, "#{role} runs #{bounds.min} to #{bounds.max} containers on #{scale.min} to #{scale.max} hosts " \
          "(replicas min #{replicas.min}, max #{replicas.max} per host), not #{count}"
      end
    end

    # Joins first, so the count never dips on the way; then the slots on the hosts that
    # stay, adds before removals; members leave between the two, so a scale-in empties
    # members before the baseline gives anything up.
    def scale_across_hosts(role, count)
      running = running_replicas(role)
      members = role.active_members
      plan = Dash::Cli::Scale::HostPlan.new(baseline: role.baseline_hosts, members: members.map(&:host), target: count,
        replicas_min: role.replicas.min, replicas_max: role.replicas.max, hosts_min: role.scale.min, hosts_max: role.scale.max)

      ensure_members_can_move(role, members, plan)
      joined = join_members(role, plan, running, count)
      running = running_replicas(role) if joined.any?

      counts = plan.counts.merge(joined.zip(plan.join_counts).to_h)
      changes = counts.to_h { |host, target| [ host, Dash::Cli::Scale::HostPlan.slot_changes(running.fetch(host, {}).keys, target) ] }
      additions = changes.transform_values(&:first).reject { |_, slots| slots.empty? }
      removals = changes.transform_values(&:last).reject { |_, slots| slots.empty? }

      if joined.empty? && plan.leaving.empty? && additions.empty? && removals.empty?
        return say "#{role} already runs #{count} containers", :magenta
      end

      scale_out(role, additions, running, count) if additions.any?
      plan.leaving.each do |host|
        Dash::Cli::Scale::Leave.new(role, members.find { |member| member.host == host }, self, running: running.fetch(host, {}), count: count).run
      end
      scale_in(role, removals, running, count) if removals.any?

      say "#{role} now runs #{count} containers on #{counts.size} #{"host".pluralize(counts.size)}", :magenta
    end

    # Members named with --hosts while the provider was down cannot be powered on or off.
    def ensure_members_can_move(role, members, plan)
      return if plan.joins.zero? && plan.leaving.empty?

      if members.any? { |member| !member.verified }
        raise ArgumentError, "#{role} needs members to #{plan.joins.positive? ? "join" : "leave"}, but its pool could not be read; " \
          "dash scale set only changes the containers on the hosts it has until the provider answers"
      end

      if role.scale.power? && (stopped = role.members.count(&:stopped?)) < plan.joins
        raise ArgumentError, "#{role} needs #{plan.joins} more #{"host".pluralize(plan.joins)} but has #{stopped} stopped " \
          "#{"member".pluralize(stopped)} to power on (see dash doctor for the labels a member carries)"
      end
    end

    def join_members(role, plan, running, count)
      return [] if plan.joins.zero?

      version = join_version(role, running)
      stopped = role.members.select(&:stopped?)

      plan.joins.times.map do |index|
        Dash::Cli::Scale::Join.new(role, self, member: (stopped[index] if role.scale.power?), version: version, count: count,
          keep_on_failure: options[:keep_on_failure]).run
      end
    end

    # The version the role runs, baseline first - never this checkout's version.
    def join_version(role, running)
      replicas = role.hosts.lazy.map { |host| running.fetch(host, {}) }.find(&:any?)
      raise Dash::Cli::BootError, "No running version of #{role} to join a member at; run dash deploy first" unless replicas

      host_version(role, replicas)
    end

    # { host => { replica => version } } for every running container of the role, one
    # `docker ps` per host. Hosts run in parallel threads, so the hash is guarded.
    def running_replicas(role)
      running = {}
      mutex = Mutex.new

      on(role.hosts) do |host|
        names = capture_with_info(*DASH.app(role: role, host: host).active_containers).lines.map(&:strip)
        replicas = names.filter_map { |name| [ role.replica_from_name(name), role.version_from_name(name) ] if role.replica_from_name(name) }.reverse.to_h

        mutex.synchronize { running[host.to_s] = replicas }
      end

      role.hosts.to_h { |host| [ host, running.fetch(host, {}) ] }
    end

    # New replicas boot at the version their host already runs. Hosts are grouped by that
    # version because the image a container runs comes from the one shared config.
    def scale_out(role, additions, running, count)
      hosts = role.hosts & additions.keys
      run_hook "pre-scale-out", role: role.name, hosts: hosts.join(","), replicas: count.to_s

      hosts.group_by { |host| host_version(role, running[host]) }.each do |version, group|
        using_version(version) do
          on(group) do |host|
            Dash::Cli::Scale::ReplicaJoin.new(host, role, additions.fetch(host.to_s), self, running: running[host.to_s].keys).run
          end
        end

        group.each { |host| additions[host].each { |replica| say "Added #{role.replica_name(replica, version)} on #{host}" } }
      end

      run_hook "post-scale-out", role: role.name, hosts: hosts.join(","), replicas: count.to_s
    end

    def scale_in(role, removals, running, count)
      hosts = role.hosts & removals.keys
      run_hook "pre-scale-in", role: role.name, hosts: hosts.join(","), replicas: count.to_s

      on(hosts) do |host|
        leaving = removals.fetch(host.to_s).to_h { |replica| [ replica, running[host.to_s][replica] ] }
        Dash::Cli::Scale::ReplicaLeave.new(host, role, leaving, self, running: running[host.to_s].keys).run
      end

      removals.each { |host, replicas| replicas.each { |replica| say "Removed #{role.replica_name(replica, running[host][replica])} on #{host}" } }

      run_hook "post-scale-in", role: role.name, hosts: hosts.join(","), replicas: count.to_s
    end

    # The version names the image, so a container a boot renamed out of the way
    # (`<version>_replaced_<hex>`) still runs `<version>`.
    def host_version(role, replicas)
      version = replicas[1] || replicas.values.first || raise(Dash::Cli::BootError, "Nothing of #{role} runs on a host to scale from, deploy it first")
      version.sub(/_replaced_\h{16}\z/, "")
    end

    def using_version(version)
      old_version = DASH.config.version
      DASH.config.version = version
      yield
    ensure
      DASH.config.version = old_version
    end

    def print_status(role)
      say "#{role[:role]}: #{role[:total]} #{"container".pluralize(role[:total])} (replicas min #{role[:min]}, max #{role[:max]} per host)"

      role[:hosts].each do |host, replicas|
        say format("  %-20s %-3s %s", host, "-", "no replicas running") if replicas.empty?

        replicas.each do |replica|
          say format("  %-20s %-3s %-20s %s", host, replica[:replica], replica[:version], replica[:status])
        end
      end

      role[:unread].each { |host| say format("  %-20s %-3s %s", host[:host], "-", "could not read (#{host[:error]})"), :red }
    end
end
