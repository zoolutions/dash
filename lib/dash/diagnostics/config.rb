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
        config: json_safe(Dash::Utils.redacted(config.to_h)) }
    end

    # config.to_h is built for YAML: symbols, and an SSH jump host as a Net::SSH object.
    def json_safe(value)
      case value
      when Hash then value.transform_values { |nested| json_safe(nested) }
      when Array then value.map { |element| json_safe(element) }
      when String, Numeric, true, false, nil then value
      when Symbol then value.to_s
      when Net::SSH::Proxy::Jump then "jump #{value.jump_proxies}"
      when Net::SSH::Proxy::Command then "command #{value.command_line_template}"
      else value.class.name
      end
    end

    def role_topology(role)
      { name: role.name, hosts: role.hosts, primary: role.primary?, proxied: role.running_proxy?,
        replicas: { min: role.replicas.min, max: role.replicas.max } }
    end
end
