# Checks on the pool members of scaled roles: whether the provider answers, whether a
# `power` role has enough members to reach its max, which members are stuck in a state
# that is neither on nor off, and whether a scaled role behind dash-proxy is load balanced.
# A provider failure is a failing result, never an exception.
class Dash::Diagnostics::Doctor::PoolChecks
  def run
    DASH.config.scaled_roles.flat_map { |role| role_results(role) }
  end

  private
    def result(target, status, detail)
      Dash::Diagnostics::Doctor::Result.new(:pool, target, status, detail)
    end

    def role_results(role)
      members = role.members

      [ provider_result(role, members), capacity_result(role, members), *stuck_results(role, members), loadbalancer_result(role) ].compact
    rescue Dash::Autoscale::ProviderError => e
      [ result(role.name, :fail, e.message), loadbalancer_result(role) ].compact
    end

    def provider_result(role, members)
      active = members.count(&:started?)
      result role.name, :ok, "#{DASH.config.autoscale.provider_name} answered: #{members.size} #{"member".pluralize(members.size)}, #{active} started"
    end

    def capacity_result(role, members)
      if role.scale.create?
        result role.name, :ok, "creates members from its template, up to #{role.scale.max} hosts"
      else
        needed = role.scale.max - role.baseline_hosts.size

        if members.size >= needed
          result role.name, :ok, "#{members.size} #{"member".pluralize(members.size)} for the #{needed} it can scale out to (max #{role.scale.max} hosts)"
        else
          result role.name, :warn, "#{members.size} of the #{needed} members max #{role.scale.max} needs carry its labels " \
            "(#{DASH.config.pool.labels_for(role).map { |key, value| "#{key}=#{value}" }.join(", ")}); it cannot scale past #{role.baseline_hosts.size + members.size} hosts"
        end
      end
    end

    def stuck_results(role, members)
      members.select(&:transitional?).map do |member|
        result "#{role.name} #{member.id}", :warn, "member #{member.host || member.id} is #{member.state}, dash leaves it alone until it is started or stopped"
      end
    end

    def loadbalancer_result(role)
      return unless role.running_proxy?

      if DASH.config.proxy.load_balancing?
        result role.name, :ok, "load balanced by #{DASH.config.proxy.effective_loadbalancer}"
      else
        result role.name, :fail, "a scaled role behind dash-proxy needs the load balancer"
      end
    end
end
