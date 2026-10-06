# Brings one pool member into a scaled role: powers a stopped member on (or creates one
# from the template), waits for SSH, then runs what a deploy would run on a new host -
# bootstrap (created members only), registry login, the stale-container sweep, the proxy
# for a proxied role and the app boot at the version the role already runs - narrowed to
# that host and role. A proxied member joins the load balancer last, once it is healthy.
#
# The sweep comes before the boot on purpose: a member powered off outside dash resumes
# its old container under `restart: unless-stopped`, and a worker would consume jobs with
# old code until the boot replaced it.
#
# Anything failing after the power-on powers the member off again (or destroys it), unless
# --keep-on-failure, so a failed join never leaves a running host with nothing on it.
class Dash::Cli::Scale::Join
  SSH_RETRY_INTERVAL = 5

  attr_reader :role, :cli, :version, :count

  def initialize(role, cli, version:, count:, member: nil, keep_on_failure: false)
    @role = role
    @cli = cli
    @member = member
    @version = version
    @count = count
    @keep_on_failure = keep_on_failure
  end

  # The member's host, once it serves.
  def run
    deadline = monotonic_now + role.scale.boot_timeout

    begin
      member = power_on
      host = joined_host(member)
      wait_for_ssh(host, deadline)
      cli.run_hook "pre-scale-out", role: role.name, hosts: host, replicas: count.to_s

      cli.narrowed_to(host, role) do
        cli.invoke_narrowed "dash:cli:server:bootstrap", Dash::Cli::Server if created?
        cli.invoke_narrowed "dash:cli:registry:login", Dash::Cli::Registry, skip_local: true
        cli.invoke_narrowed "dash:cli:app:stale_containers", Dash::Cli::App, stop: true
        cli.invoke_narrowed "dash:cli:proxy:boot", Dash::Cli::Proxy, skip_loadbalancer: true if role.running_proxy?
        cli.invoke_narrowed "dash:cli:app:boot", Dash::Cli::App, version: version
      end

      if role.running_proxy?
        cli.deploy_loadbalancer
        @in_loadbalancer = host
      end
      cli.run_hook "post-scale-out", role: role.name, hosts: host, replicas: count.to_s
      cli.report "Joined #{member.id} (#{host}) to #{role}"
      host
    rescue StandardError => e
      # The created server, or the member started; nil when a create failed before the
      # provider returned one, and then there is nothing to power off.
      member = @created || @member

      unless @keep_on_failure
        # Out of the load balancer before it goes, or it would forward to a stopped host.
        cli.deploy_loadbalancer(except: @in_loadbalancer) if @in_loadbalancer
        power_off(member) if member
      end

      raise e
    end
  end

  private
    def created?
      @member.nil?
    end

    def power_on
      if created?
        cli.report "Creating a #{role} member...", :magenta
        @created = provider.create(labels: pool.labels_for(role), template: role.scale.template, address: role.scale.address)
      else
        cli.report "Powering on #{@member.id} (#{@member.host}) for #{role}...", :magenta
        provider.start(@member)
      end

      provider.wait_until(@created || @member, state: "started", timeout: role.scale.boot_timeout)
      @created || @member
    end

    # A created server may not have its address until it runs, so the host is read back
    # from the provider - which also puts the member into role.hosts for the narrowing.
    def joined_host(member)
      pool.refresh!
      role.active_members.find { |candidate| candidate.id == member.id }&.host ||
        raise(Dash::Autoscale::ProviderError, "#{member.id} is started but #{provider.name} does not list it among #{role}'s members")
    end

    # The bounded handshake of Dash::Cli::Base#on (zoolutions/dash#152), retried until the
    # member's boot_timeout runs out.
    def wait_for_ssh(host, deadline)
      cli.report "Waiting for #{host} to answer SSH...", :magenta

      begin
        cli.on_hosts([ host ]) { execute :true }
      rescue SSHKit::Runner::ExecuteError => e
        if monotonic_now >= deadline
          raise Dash::Cli::BootError, "#{host} did not answer SSH within #{role} scale/boot_timeout (#{role.scale.boot_timeout}s): #{e.message}"
        end

        sleep SSH_RETRY_INTERVAL
        retry
      end
    end

    def power_off(member)
      cli.report "Join failed, powering #{member.id} off again (--keep-on-failure keeps it)", :red
      Dash::Cli::Scale::PowerOff.new(role, member, provider).run(destroy: created?)
    rescue StandardError => e
      cli.report "Could not power #{member.id} off: #{e.message}", :red
    end

    def pool
      DASH.config.pool
    end

    def provider
      pool.provider
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
