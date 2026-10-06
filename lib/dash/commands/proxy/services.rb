require "json"

# What `dash-proxy list --json` answers, for the per-host proxy and the load balancer
# alike: {"services": {"<name>": {"host":, "targets": [...], ...}}}. One parser for the
# reboots' verification and the diagnostics, so they cannot read the list differently.
module Dash::Commands::Proxy::Services
  def self.parse(output)
    JSON.parse(output).fetch("services", {})
  end
end
