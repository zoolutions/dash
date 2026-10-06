require "json"

# One line of the app's `docker ps` in Commands::App::Containers::PS_WITH_ROLE_FORMAT - the
# container's JSON, a tab, docker's own value of its `role` label - as a container of this
# deploy. The role comes from that label value, never from the name alone (a sibling role
# whose name extends another's would be misattributed) and never from the rendered `Labels`
# string (a comma in another label's value could pass for a role there).
module Dash::Diagnostics::DockerPs
  HEALTH = /\((healthy|unhealthy|health: starting)\)/

  module_function

  # An accessory's containers carry only its `service` label, so they are named for the
  # accessory the caller asked about rather than for a role; their lines are plain JSON.
  def containers(output, accessory: nil)
    output.to_s.lines.filter_map do |line|
      next if line.strip.empty?

      ps, role = line.chomp.split("\t", 2)
      accessory ? accessory_container(JSON.parse(ps), accessory) : container(JSON.parse(ps), role && JSON.parse(role))
    end
  end

  def accessory_container(ps, accessory)
    { name: ps["Names"], id: ps["ID"], accessory: accessory, state: ps["State"], status: ps["Status"], health: ps["Status"].to_s[HEALTH, 1],
      image: ps["Image"], created_at: ps["CreatedAt"] }
  end

  def container(ps, role_name)
    role = DASH.config.role(role_name) if role_name.present?
    name = ps["Names"]

    {
      name: name, id: ps["ID"], role: role_name.presence,
      replica: role&.replica_from_name(name), version: role&.version_from_name(name),
      state: ps["State"], status: ps["Status"], health: ps["Status"].to_s[HEALTH, 1],
      image: ps["Image"], created_at: ps["CreatedAt"]
    }
  end
end
