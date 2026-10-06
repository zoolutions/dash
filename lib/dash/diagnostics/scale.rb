# The shape of `dash scale status --json`: per role its bounds, its total, and per host each
# replica's slot, version and docker status - one `docker ps` per host. A host that cannot
# be read is listed under the role's `unread` rather than shown as running nothing.
class Dash::Diagnostics::Scale < Dash::Diagnostics::Base
  def initialize(roles: DASH.roles)
    @roles = roles
  end

  private
    def snapshot
      { roles: @roles.map { |role| role_status(role) } }
    end

    def role_status(role)
      read = per_host(role.hosts & DASH.hosts) { |backend, host| { replicas: replicas(role, backend.capture_with_info(*DASH.app(role: role, host: host).replica_status)) } }
      hosts = read.reject { |host| host[:error] }.to_h { |host| [ host[:host], host[:replicas] ] }

      { role: role.name, min: role.replicas.min, max: role.replicas.max, total: hosts.values.sum(&:size),
        unread: read.select { |host| host[:error] }, hosts: hosts }
    end

    # `docker ps` lines of "<name>\t<status>"; names that are not one of the role's slots drop out.
    def replicas(role, output)
      output.lines.filter_map do |line|
        name, status = line.chomp.split("\t", 2)
        if name.present? && (replica = role.replica_from_name(name))
          { replica: replica, version: role.version_from_name(name), status: status.to_s.strip }
        end
      end.sort_by { |replica| replica[:replica] }
    end
end
