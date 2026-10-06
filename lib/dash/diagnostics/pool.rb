# The pool members of every scaled role, for `dash scale status --json` and the MCP
# `pool_members` tool: per role its provider and bounds, and per member its provider id,
# host, state, labels and whether the provider vouched for it (`verified: false` is a host
# taken from --hosts while the provider was down). Started members are read for the
# versions they run; one running nothing of the role is an `orphan`. Provider credentials
# never reach this: members carry labels, not the request that listed them.
class Dash::Diagnostics::Pool < Dash::Diagnostics::Base
  def initialize(roles: Dash::Diagnostics::Doctor.scoped_roles.select(&:scaled?))
    @roles = roles
  end

  private
    def snapshot
      { roles: @roles.map { |role| role_pool(role) } }
    end

    def role_pool(role)
      head = { role: role.name, provider: DASH.config.autoscale.provider_name, members: role.scale.members.to_s,
        min: role.scale.min, max: role.scale.max, baseline: in_scope(role.baseline_hosts) }
      members = role.members.select { |member| in_scope([ member.host ]).any? }
      read = per_host(members.select(&:started?).map(&:host)) do |backend, host|
        { versions: Dash::Diagnostics::Scale.replicas(role, backend.capture_with_info(*DASH.app(role: role, host: host).replica_status)).map { |replica| replica[:version] }.uniq }
      end.index_by { |entry| entry[:host] }

      head.merge(pool: members.map { |member| member_entry(member, read[member.host]) })
    rescue Dash::Autoscale::ProviderError => e
      head.merge(error: e.message)
    end

    # The run's --hosts, read directly: DASH.hosts would expand every role's hosts, and one
    # other pool that cannot be read would fail this role too.
    def in_scope(hosts)
      DASH.specific_hosts ? hosts & DASH.specific_hosts : hosts
    end

    def member_entry(member, read)
      entry = { id: member.id, host: member.host, state: member.state, labels: member.labels, verified: member.verified,
        versions: read&.fetch(:versions, nil) || [], orphan: !!(read && read[:versions]&.empty?) }
      read&.key?(:error) ? entry.merge(error: read[:error]) : entry
    end
end
