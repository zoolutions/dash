require "json"

# Per app host, every container of this service and destination: role, replica slot,
# version, state and health. One `docker ps` per host, whatever the roles and slots.
class Dash::Diagnostics::Containers < Dash::Diagnostics::Base
  HEALTH = /\((healthy|unhealthy|health: starting)\)/

  def initialize(hosts: DASH.app_hosts)
    @hosts = hosts
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| { containers: containers(backend.capture_with_info(*DASH.app.list_containers_json)) } } }
    end

    def containers(output)
      output.lines.filter_map { |line| container(JSON.parse(line)) if line.strip.present? }
    end

    def container(ps)
      labels = labels(ps["Labels"])
      role = DASH.config.role(labels["role"])
      name = ps["Names"]

      {
        name: name, id: ps["ID"], role: labels["role"],
        replica: role&.replica_from_name(name), version: role&.version_from_name(name),
        state: ps["State"], status: ps["Status"], health: ps["Status"].to_s[HEALTH, 1],
        image: ps["Image"], created_at: ps["CreatedAt"]
      }
    end

    # docker renders labels as "key=value,key=value", so a value carrying a comma leaves
    # fragments with no "=". They are dropped; dash's own labels have no commas.
    def labels(rendered)
      rendered.to_s.split(",").filter_map { |pair| pair.split("=", 2) if pair.include?("=") }.to_h
    end
end
