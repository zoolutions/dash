# Compares what should be running with what is: the containers on each host against the
# targets dash-proxy routes to there, against the load balancer's targets. Pure - it reads
# the Containers, ProxyServices and Lock snapshots and touches nothing; `.take` captures
# them first.
#
# Each mismatch is `{ code:, host:, role:, detail: }`, with a code an agent can branch on:
#
#   proxy_target_not_running     the proxy routes to a container that is not running
#   running_not_targeted         a running container of a proxied role is not a target
#   loadbalancer_target_missing  a host the load balancer should forward to is not a target
#   loadbalancer_target_extra    the load balancer forwards to a host it should not
#   version_mismatch             a role's hosts run different versions
#   multiple_running_versions    one host runs more than one version of a role
#   member_not_targeted          a started pool member the load balancer does not forward to
#                                (reported instead of loadbalancer_target_missing for it)
#   member_orphan                a started pool member runs nothing of its role
#
# A host whose snapshot is an error is not compared; it is listed under `unread` instead,
# and the fleet is not called consistent.
# While the deploy lock is held the version codes are skipped too - a deploy in flight runs
# two versions on purpose - and `lock_held` says so (nil when the lock was not read).
class Dash::Diagnostics::Drift < Dash::Diagnostics::Base
  FAILURES = %w[ proxy_target_not_running loadbalancer_target_missing ].freeze
  REPLACED_SUFFIX = /_replaced_\h{16}\z/
  TARGET_KEYS = %w[ targets reader_targets rollout_targets ].freeze

  # The lock is only read when the primary host is in scope; narrowed away from it, the
  # version codes are reported whether or not a deploy is in flight.
  def self.take
    lock = Dash::Diagnostics::Lock.new.to_h if DASH.hosts.include?(DASH.config.primary_host)

    new(containers: Dash::Diagnostics::Containers.new(accessories: []).to_h, proxy_services: Dash::Diagnostics::ProxyServices.new.to_h, lock: lock)
  end

  def initialize(containers:, proxy_services:, lock: nil, config: nil)
    @containers = containers
    @proxy_services = proxy_services
    @lock = lock
    @config = config
  end

  def entries
    @entries ||= proxy_entries + loadbalancer_entries + member_entries + version_entries
  end

  # The hosts whose containers or routes could not be read, so were not compared. A fleet
  # with any is not reported consistent: no drift found is not the same as none there.
  def unread
    @unread ||= [ [ "containers", Array(@containers[:hosts]) ], [ "proxy_services", [ *@proxy_services[:hosts], @proxy_services[:loadbalancer] ].compact ] ]
      .flat_map { |source, hosts| hosts.select { |host| host[:error] }.map { |host| { host: host[:host], source: source, error: host[:error] } } }
  end

  private
    def snapshot
      { consistent: entries.empty? && unread.empty?, lock_held: @lock&.dig(:lock, :held), drift: entries, unread: unread }
    end

    def proxy_entries
      Array(@proxy_services[:hosts]).reject { |host| host[:error] }.flat_map do |proxy_host|
        host = proxy_host[:host]
        next [] unless running.key?(host)

        proxied_roles_on(host).flat_map { |role| role_proxy_entries(role, host, targets(proxy_host[:services].to_h[role.container_prefix])) }
      end
    end

    def role_proxy_entries(role, host, targets)
      containers = running[host].select { |container| container[:role] == role.name }

      not_running = targets.reject { |target| containers.any? { |container| container[:id].to_s.start_with?(target) } }.map do |target|
        entry "proxy_target_not_running", host, role, "#{role.container_prefix} routes to #{target}, which is not a running container"
      end

      not_targeted = containers.reject { |container| targets.any? { |target| container[:id].to_s.start_with?(target) } }.map do |container|
        entry "running_not_targeted", host, role, "#{container[:name]} (replica #{container[:replica]}) runs but #{role.container_prefix} does not route to it"
      end

      not_running + not_targeted
    end

    def loadbalancer_entries
      loadbalancer = @proxy_services[:loadbalancer]
      return [] if loadbalancer.nil? || loadbalancer[:error]

      expected = Dash::Configuration::Loadbalancer.new(config: config, proxy_config: config.proxy.proxy_config, secrets: config.secrets).target_hosts.uniq
      actual = targets(loadbalancer[:services].to_h[config.service])
      host = loadbalancer[:host]

      (expected - actual).map { |target| missing_target_entry(host, target) } +
        (actual - expected).map { |target| entry "loadbalancer_target_extra", host, nil, "the load balancer forwards to #{target}, which no proxied role runs on" }
    end

    # A member that joined but never reached the load balancer serves nobody: capacity paid
    # for and wasted, not a broken route - so it is its own code, not a failure.
    def missing_target_entry(host, target)
      if (member = started_members.find { |candidate| candidate.host == target })
        role = config.roles.find { |candidate| candidate.name == member.role }
        entry "member_not_targeted", host, role, "member #{member.id} (#{target}) is started but the load balancer does not forward to it"
      else
        entry "loadbalancer_target_missing", host, nil, "the load balancer does not forward to #{target}"
      end
    end

    def member_entries
      config.scaled_roles.flat_map do |role|
        role.active_members.filter_map do |member|
          next unless running.key?(member.host)
          next if running[member.host].any? { |container| container[:role] == role.name }

          entry "member_orphan", member.host, role, "member #{member.id} is started but runs no #{role} container"
        end
      end
    end

    def started_members
      @started_members ||= config.scaled_roles.flat_map(&:active_members)
    end

    def version_entries
      return [] if @lock&.dig(:lock, :held)

      config.roles.flat_map do |role|
        by_host = running.transform_values { |containers| versions(containers.select { |container| container[:role] == role.name }) }.reject { |_, versions| versions.empty? }

        multiple = by_host.select { |_, versions| versions.size > 1 }.map do |host, versions|
          entry "multiple_running_versions", host, role, "#{role} runs #{versions.join(", ")} on #{host}"
        end

        mismatch = if by_host.values.uniq.size > 1
          [ entry("version_mismatch", nil, role, "#{role} runs " + by_host.map { |host, versions| "#{versions.join("+")} on #{host}" }.join(", ")) ]
        end

        multiple + mismatch.to_a
      end
    end

    def config
      @config ||= DASH.config
    end

    def running
      @running ||= Array(@containers[:hosts]).reject { |host| host[:error] }.to_h do |host|
        [ host[:host], Array(host[:containers]).select { |container| container[:state] == "running" } ]
      end
    end

    def proxied_roles_on(host)
      config.roles.select { |role| role.running_proxy? && role.hosts.include?(host) }
    end

    # dash-proxy lists targets as "<container id or host>:<port>"; the id is the short one
    # dash deployed with, the host is what the load balancer forwards to.
    def targets(service)
      return [] unless service

      listed = TARGET_KEYS.flat_map { |key| Array(service[key]) }
      listed = service["target"].to_s.split(",") if listed.empty?
      listed.map { |target| target.strip.sub(/:\d+\z/, "") }.reject(&:empty?).uniq
    end

    def versions(containers)
      containers.map { |container| container[:version].to_s.sub(REPLACED_SUFFIX, "") }.uniq.sort
    end

    def entry(code, host, role, detail)
      { code: code, host: host, role: role&.name, detail: detail }
    end
end
