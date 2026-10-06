# The shape of `dash scale status --json`: per role its bounds, its total, and per host each
# replica's slot, version and docker status - one `docker ps` per host. A host that cannot
# be read is listed under the role's `unread` rather than shown as running nothing.
#
# A scaled role adds its scale bounds and its pool members; a started member whose host
# lists no replica of the role is an `orphan`. A pool that cannot be read is the role's
# `error`, so one provider outage does not hide the other roles.
class Dash::Diagnostics::Scale < Dash::Diagnostics::Base
  # `docker ps` lines of "<name>\t<status>"; names that are not one of the role's slots drop out.
  def self.replicas(role, output)
    output.lines.filter_map do |line|
      name, status = line.chomp.split("\t", 2)
      if name.present? && (replica = role.replica_from_name(name))
        { replica: replica, version: role.version_from_name(name), status: status.to_s.strip }
      end
    end.sort_by { |replica| replica[:replica] }
  end

  def initialize(roles: DASH.roles)
    @roles = roles
  end

  private
    def snapshot
      { roles: @roles.map { |role| role_status(role) } }
    end

    def role_status(role)
      read = per_host(in_scope(role.hosts)) { |backend, host| { replicas: self.class.replicas(role, backend.capture_with_info(*DASH.app(role: role, host: host).replica_status)) } }
      hosts = read.reject { |host| host[:error] }.to_h { |host| [ host[:host], host[:replicas] ] }

      status = { role: role.name, min: role.replicas.min, max: role.replicas.max, total: hosts.values.sum(&:size),
        unread: read.select { |host| host[:error] }, hosts: hosts }
      status.merge!(scale: { min: role.scale.min, max: role.scale.max }, members: members(role, hosts)) if role.scaled?
      status
    rescue Dash::Autoscale::ProviderError => e
      { role: role.name, error: e.message }
    end

    # The run's --hosts, read directly: DASH.hosts would expand every role's hosts, and one
    # other pool that cannot be read would fail this role too.
    def in_scope(hosts)
      DASH.specific_hosts ? hosts & DASH.specific_hosts : hosts
    end

    def members(role, hosts)
      role.members.map do |member|
        { id: member.id, host: member.host, state: member.state, orphan: member.started? && hosts.key?(member.host) && hosts[member.host].empty? }
      end
    end
end
