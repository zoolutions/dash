require "json"

# One line of `docker ps --format '{{json .}}'` as a container of this deploy: its role and
# replica slot come from the `role` label, never from the name alone - a sibling role whose
# name extends another's would otherwise be misattributed.
module Dash::Diagnostics::DockerPs
  HEALTH = /\((healthy|unhealthy|health: starting)\)/

  module_function

  def containers(output)
    output.to_s.lines.filter_map { |line| container(JSON.parse(line)) if line.strip.present? }
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
