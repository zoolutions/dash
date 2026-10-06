# Takes one pool member out of a scaled role. A proxied member leaves the load balancer
# first - the redeploy without it drains its in-flight requests - and its containers stop
# after. A worker member is drained slot by slot (drain signal, drain wait, stop) the way a
# replica scale-in is. Then the provider powers it off, or deletes it for `members: create`.
# A baseline host never leaves: dash scale does not stop what deploy.yml lists.
class Dash::Cli::Scale::Leave
  attr_reader :role, :member, :cli, :count

  # `running` is { replica => version } on the member.
  def initialize(role, member, cli, running:, count:)
    @role = role
    @member = member
    @cli = cli
    @running = running
    @count = count
  end

  def run
    host = member.host
    raise ArgumentError, "#{host} is a baseline host of #{role}, dash scale never stops it" if role.baseline_hosts.include?(host)

    cli.run_hook "pre-scale-in", role: role.name, hosts: host, replicas: count.to_s
    cli.report "Removing #{member.id} (#{host}) from #{role}...", :magenta

    cli.deploy_loadbalancer(except: host) if role.running_proxy?
    stop_containers(host)
    Dash::Cli::Scale::PowerOff.new(role, member, DASH.config.pool.provider).run(destroy: role.scale.create?)
    DASH.config.pool.refresh!

    cli.run_hook "post-scale-in", role: role.name, hosts: host, replicas: count.to_s
    cli.report "Removed #{member.id} (#{host}) from #{role}"
  end

  private
    def stop_containers(host)
      role, running = self.role, @running

      cli.on_hosts([ host ]) do
        if running.empty?
          # An orphan: nothing of the role to stop or drain.
        elsif role.running_proxy?
          running.each { |replica, version| execute *DASH.app(role: role, host: host, replica: replica).stop(version: version) }
        else
          Dash::Cli::Scale::ReplicaLeave.new(host, role, running, self, running: running.keys).run
        end
      end
    end
end
