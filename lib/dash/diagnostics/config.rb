# The effective configuration as `dash config` prints it (secrets as their redaction),
# plus the topology an agent would otherwise have to derive: which hosts each role runs
# on, which roles are proxied, and where the proxies and the load balancer are.
class Dash::Diagnostics::Config < Dash::Diagnostics::Base
  private
    def snapshot
      config = DASH.config

      { service: config.service, destination: config.destination, roles: config.roles.map { |role| role_topology(role) },
        proxy: { hosts: config.proxy_hosts, loadbalancer: (config.proxy.effective_loadbalancer.presence if config.proxy.load_balancing?) },
        accessories: config.accessories.map { |accessory| { name: accessory.name, hosts: accessory.hosts } },
        config: Dash::Utils.redacted(config.to_h) }
    end

    def role_topology(role)
      { name: role.name, hosts: role.hosts, primary: role.primary?, proxied: role.running_proxy?,
        replicas: { min: role.replicas.min, max: role.replicas.max } }
    end
end
