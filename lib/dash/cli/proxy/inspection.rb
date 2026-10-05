# The human renderings of `dash proxy services` and `dash proxy drift`. The JSON is the
# diagnostic's own `to_h`; this is only the table an operator reads.
module Dash::Cli::Proxy::Inspection
  extend self

  def services_lines(snapshot)
    proxies = snapshot[:hosts].flat_map { |host| host_services_lines("Proxy", host) }
    proxies + (snapshot[:loadbalancer] ? host_services_lines("Loadbalancer", snapshot[:loadbalancer]) : [])
  end

  def drift_lines(snapshot)
    if snapshot[:consistent]
      [ "No drift: proxy targets match the running containers" ]
    else
      snapshot[:drift].map { |entry| "#{entry[:code]} #{entry[:host] || entry[:role]}: #{entry[:detail]}" }
    end
  end

  private
    def host_services_lines(type, host)
      return [ "#{type} Host: #{host[:host]}", "  ERROR #{host[:error]}" ] if host[:error]

      services = host[:services].map do |name, service|
        targets = Array(service["targets"]).presence || service["target"].to_s.split(",")
        "  #{name} #{service["host"].presence || "*"} -> #{targets.join(", ").presence || "no targets"}#{" (#{service["state"]})" if service["state"]}"
      end

      [ "#{type} Host: #{host[:host]}", *services.presence || [ "  no services" ] ]
    end
end
