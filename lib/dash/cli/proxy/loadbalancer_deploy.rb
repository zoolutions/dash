# Points the load balancer at a target list: every host of every proxied role by default.
# `dash proxy loadbalancer deploy` and `dash scale set` share it, so a member leaving the
# pool is the same deploy with that host left out - dash-proxy replaces the whole list,
# draining the hosts that are no longer on it. Runs inside `on(<load balancer host>)`.
class Dash::Cli::Proxy::LoadbalancerDeploy
  attr_reader :host, :sshkit
  delegate :execute, :info, to: :sshkit

  def initialize(host, sshkit, targets: DASH.loadbalancer_config.target_hosts)
    @host = host
    @sshkit = sshkit
    @targets = targets
  end

  def run
    Dash::Cli::Proxy::LoadbalancerClaim.new(host, sshkit).claim_service
    info "Deploying to loadbalancer on #{host} with targets: #{@targets.join(', ')}"
    execute *DASH.loadbalancer.deploy(targets: @targets)
  end
end
