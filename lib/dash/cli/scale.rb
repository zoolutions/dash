# Changes how many containers of a role run, at runtime, at the version already running -
# no build and no deploy. The count is in containers across the role's hosts, like Heroku
# dynos, spread evenly within each host's `replicas` bounds. A later deploy keeps it,
# because a deploy boots as many replicas as are running.
class Dash::Cli::Scale < Dash::Cli::Base
  desc "set ROLE COUNT", "Run COUNT containers of ROLE across its hosts, within its replicas bounds"
  def set(role_name, count)
    role = scalable_role(role_name)
    count = Integer(count, 10)
    ensure_within_bounds(role, count)

    modify(lock: true) do
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
    scale = Dash::Diagnostics::Scale.new(roles.map { |role| [ role, replica_status(role) ] })

    if options[:json]
      puts JSON.pretty_generate(scale.to_h)
    else
      scale.to_h[:roles].each { |role| print_status(role) }
    end
  end

  private
    def scalable_role(role_name)
      DASH.config.role(role_name) || raise(ArgumentError, "No role named #{role_name}, expected one of #{DASH.config.roles.map(&:name).join(", ")}")
    end

    def ensure_within_bounds(role, count)
      hosts = role.hosts.size
      bounds = (hosts * role.replicas.min)..(hosts * role.replicas.max)

      unless bounds.cover?(count)
        raise ArgumentError, "#{role} runs #{bounds.min} to #{bounds.max} containers on its #{hosts} #{"host".pluralize(hosts)} " \
          "(replicas min #{role.replicas.min}, max #{role.replicas.max} per host), not #{count}"
      end
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

    # { host => [ [ name, status ] ] }, one `docker ps` per host.
    def replica_status(role)
      statuses = {}
      mutex = Mutex.new

      on(role.hosts) do |host|
        lines = capture_with_info(*DASH.app(role: role, host: host).replica_status).lines
        mutex.synchronize { statuses[host.to_s] = lines.map { |line| line.chomp.split("\t", 2) }.reject { |name, _| name.blank? } }
      end

      role.hosts.to_h { |host| [ host, statuses.fetch(host, []) ] }
    end

    def print_status(role)
      say "#{role[:role]}: #{role[:total]} #{"container".pluralize(role[:total])} (replicas min #{role[:min]}, max #{role[:max]} per host)"

      role[:hosts].each do |host, replicas|
        say format("  %-20s %-3s %s", host, "-", "no replicas running") if replicas.empty?

        replicas.each do |replica|
          say format("  %-20s %-3s %-20s %s", host, replica[:replica], replica[:version], replica[:status])
        end
      end
    end
end
