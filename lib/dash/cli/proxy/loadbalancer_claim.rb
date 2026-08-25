# Ownership bookkeeping for a load balancer host that more than one dash app
# may be deploying to. Kamal only ever sees one deploy.yml at a time, so the
# other apps are visible solely through the files they left on the host.
class Dash::Cli::Proxy::LoadbalancerClaim
  attr_reader :host, :sshkit
  delegate :capture_with_info, :execute, :upload!, :warn, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  # The load balancer registers services under the bare service name, so a
  # second app - or a second destination of this app - deploying the same name
  # would silently take over its routes. Claim the name on first deploy and fail
  # loudly rather than quietly stealing it.
  def claim_service
    owner = capture_with_info(*commands.read_service_owner, raise_on_non_zero_exit: false).strip

    if owner.present? && owner != config.owner_token
      raise "Service '#{config.config.service}' is already registered on the load balancer at #{host} by #{repository_in(owner)}. " \
            "Deploying would take over its routes - rename this app's service or use a different load balancer."
    end

    execute *commands.ensure_services_directory
    upload! StringIO.new(config.owner_token), config.service_owner_file
  end

  # Every app sharing a load balancer boots the same container, so their
  # proxy/run configurations have to agree. A mismatch owned by another app is
  # an error; a mismatch owned by this app is ordinary drift, reported the same
  # way the per-host proxy reports it and fixed by `dash proxy reboot`.
  def claim_run_config(replace: false)
    record = capture_with_info(*commands.read_run_config_record, raise_on_non_zero_exit: false).strip

    if record.present?
      *owner_parts, digest = record.split(" ")
      owner = owner_parts.join(" ")

      if digest != config.run_config_digest
        if owner != config.owner_token
          raise "The load balancer on #{host} was booted by #{repository_in(owner)} with a different proxy/run configuration. " \
                "Apps sharing a load balancer must agree on proxy/run - align the configurations or use a different load balancer host."
        elsif !replace
          warn "The load balancer on #{host} is running with a configuration that no longer matches the deploy config - " \
               "run `dash proxy reboot` to apply the new configuration."
          return
        end
      end
    end

    execute *commands.ensure_directory
    upload! StringIO.new(config.run_config_record), config.run_config_file
  end

  private
    def config
      DASH.loadbalancer_config
    end

    def commands
      DASH.loadbalancer
    end

    # Owner tokens are "<service-and-destination> <repository>"; the repository
    # is the half an operator recognises as "the other app".
    def repository_in(owner)
      owner.split(" ").last
    end
end
