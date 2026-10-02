# The shape of `dash scale status --json`: per role its bounds, its total, and per host each
# replica's slot, version and docker status. A plain object, so a diagnostics surface (an
# MCP tool, a health report) can serve the same document.
class Dash::Diagnostics::Scale
  # [ [ role, { host => [ [ container_name, status ] ] } ] ]
  def initialize(statuses)
    @statuses = statuses
  end

  def to_h
    { roles: @statuses.map { |role, hosts| role_status(role, hosts) } }
  end

  private
    def role_status(role, hosts)
      replicas = hosts.to_h do |host, containers|
        [ host, containers.filter_map { |name, status| replica_status(role, name, status) }.sort_by { |replica| replica[:replica] } ]
      end

      { role: role.name, min: role.replicas.min, max: role.replicas.max, total: replicas.values.sum(&:size), hosts: replicas }
    end

    def replica_status(role, name, status)
      if (replica = role.replica_from_name(name))
        { replica: replica, version: role.version_from_name(name), status: status.to_s.strip }
      end
    end
end
