# Per proxy host, what dash-proxy routes for this deploy (`dash-proxy list --json`), and
# the load balancer's routes when load balancing is on.
#
# Only this deploy's own services are kept: a proxy host serves every app and destination
# deployed to it, and the others are neither this deploy's business nor worth handing to
# an agent.
class Dash::Diagnostics::ProxyServices < Dash::Diagnostics::Base
  def initialize(hosts: DASH.proxy_hosts)
    @hosts = hosts
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, host| { services: own(services(backend, DASH.proxy(host).list(json: true)), host) } },
        loadbalancer: loadbalancer }
    end

    def loadbalancer
      if DASH.config.proxy.load_balancing? && (host = DASH.config.proxy.effective_loadbalancer)
        per_host([ host ]) { |backend, _host| { services: services(backend, DASH.loadbalancer.list(json: true)).slice(DASH.config.service) } }.first
      end
    end

    def services(backend, command)
      Dash::Commands::Proxy::Services.parse(backend.capture_with_info(*command))
    end

    def own(services, host)
      services.slice(*service_names(host))
    end

    def service_names(host)
      DASH.config.roles.select { |role| role.running_proxy? && role.hosts.include?(host) }.map(&:container_prefix) +
        DASH.config.accessories.select { |accessory| accessory.running_proxy? && accessory.hosts.include?(host) }.map(&:service_name)
    end
end
