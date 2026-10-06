# The pool members of every scaled role, as the provider reports them. The configuration
# owns one and Role#hosts reads it, so members are asked for on the first `hosts` read and
# then once per process per role - `refresh!` asks again.
#
# Degraded mode lives here and only here. When the provider cannot be asked and the command
# named hosts with --hosts, the named hosts that are not baseline hosts are taken as
# started members, unverified, of the one scaled role in scope (--roles narrows it), with a
# warning. Without --hosts, or with more than one scaled role it could mean, the provider
# error stands: dash never guesses which hosts are running.
class Dash::Autoscale::Pool
  attr_reader :config, :explicit_hosts, :explicit_roles

  def initialize(config:, explicit_hosts: nil, explicit_roles: nil)
    @config = config
    @explicit_hosts = Array(explicit_hosts).presence
    @explicit_roles = Array(explicit_roles).presence
    @members = {}
    @mutex = Mutex.new
  end

  # `on` runs host blocks in threads, and any of them may be the first to read a role's
  # hosts; the lock keeps that to one provider call. A failure is kept too, so a provider
  # that is down costs one timeout per process, not one per `hosts` read.
  def members_for(role)
    members = @mutex.synchronize do
      @members[role.name] ||= begin
        resolve(role)
      rescue Dash::Autoscale::ProviderError => e
        e
      end
    end

    raise members if members.is_a?(Exception)
    members
  end

  def active_for(role)
    members_for(role).select(&:started?)
  end

  def refresh!
    @mutex.synchronize { @members.clear }
    self
  end

  def provider
    @provider ||= Dash::Autoscale::Provider.for(config.autoscale)
  end

  def labels_for(role)
    { "dash.service" => config.service, "dash.destination" => config.destination || "-", "dash.role" => role.name }
  end

  private
    def resolve(role)
      provider.members(labels: labels_for(role), address: role.scale.address)
    # A credential that resolves to nothing only surfaces here, on the first request.
    rescue Dash::Autoscale::ProviderError, Dash::ConfigurationError => e
      degraded(role, e)
    end

    def degraded(role, error)
      raise Dash::Autoscale::ProviderError, "Could not read the #{role} pool: #{error.message}" unless explicit_hosts

      scoped = config.scaled_roles.select { |candidate| explicit_roles.nil? || Dash::Utils.filter_specific_items(explicit_roles, [ candidate ]).any? }
      return [] unless scoped.include?(role)

      if scoped.many?
        raise Dash::Autoscale::ProviderError, "Could not read the pool (#{error.message}), " \
          "and --hosts could mean members of #{scoped.map(&:name).join(" or ")}; name one with --roles"
      end

      unverified(role, error)
    end

    def unverified(role, error)
      baseline = config.roles.flat_map(&:baseline_hosts) + config.accessories.flat_map(&:hosts)
      # A wildcard names no host; only literal --hosts entries can stand in for members.
      hosts = explicit_hosts.grep_v(/[*?\[{]/) - baseline

      warn_once "Could not read the #{role} pool (#{error.message}); " \
        "taking #{hosts.any? ? hosts.join(", ") : "no hosts"} from --hosts as started members, unverified"

      hosts.map { |host| Dash::Autoscale::Member.new(id: nil, host: host, role: role.name, state: "started", labels: labels_for(role), verified: false) }
    end

    def warn_once(message)
      return if @warned

      @warned = true
      warn message
    end
end
