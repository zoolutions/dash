# `dash proxy services` and `dash proxy drift`: the read-only questions about what the
# proxies route, kept out of the proxy command file that boots, reboots and manages them.
# The JSON is the diagnostic's own `to_h`; the rest here is the table an operator reads.
module Dash::Cli::Proxy::Inspection
  extend ActiveSupport::Concern

  included do
    desc "services", "Show what dash-proxy routes for this deploy on each proxy host (and the load balancer)"
    option :json, type: :boolean, default: false, desc: "Print the services as JSON"
    def services
      return puts_json { Dash::Diagnostics::ProxyServices.new.to_h } if options[:json]

      pre_connect_if_required
      puts services_lines(Dash::Diagnostics::ProxyServices.new.to_h)
    end

    desc "drift", "Compare the running containers with the proxy and load balancer targets"
    option :json, type: :boolean, default: false, desc: "Print the drift as JSON"
    def drift
      return puts_json { Dash::Diagnostics::Drift.take.to_h } if options[:json]

      pre_connect_if_required
      puts drift_lines(Dash::Diagnostics::Drift.take.to_h)
    end
  end

  private
    def services_lines(snapshot)
      proxies = snapshot[:hosts].flat_map { |host| host_services_lines("Proxy", host) }
      proxies + (snapshot[:loadbalancer] ? host_services_lines("Loadbalancer", snapshot[:loadbalancer]) : [])
    end

    def drift_lines(snapshot)
      if snapshot[:consistent]
        [ "No drift: proxy targets match the running containers" ]
      else
        snapshot[:drift].map { |entry| "#{entry[:code]} #{entry[:host] || entry[:role]}: #{entry[:detail]}" } +
          Array(snapshot[:unread]).map { |host| "unread #{host[:host]}: could not read #{host[:source]} (#{host[:error]})" }
      end
    end

    def host_services_lines(type, host)
      return [ "#{type} Host: #{host[:host]}", "  ERROR #{host[:error]}" ] if host[:error]

      services = host[:services].map do |name, service|
        targets = Array(service["targets"]).presence || service["target"].to_s.split(",")
        "  #{name} #{service["host"].presence || "*"} -> #{targets.join(", ").presence || "no targets"}#{" (#{service["state"]})" if service["state"]}"
      end

      [ "#{type} Host: #{host[:host]}", *services.presence || [ "  no services" ] ]
    end
end
