# Replaces the loadbalancer container with one booted from the current
# configuration. Shared by `kamal proxy reboot` and the drift-detected reboot
# on boot - the same sequence either way, so the two paths cannot diverge.
#
# Unlike the proxy hosts' port-holder handoff this is stop -> run: the
# loadbalancer keeps its service state in the config volume, which the
# replacement container re-mounts, so every app's routes survive the gap.
class Kamal::Cli::Proxy::LoadbalancerReboot
  attr_reader :host, :sshkit
  delegate :execute, :capture_with_info, :info, :upload!, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    execute *KAMAL.auditor.record("Rebooted loadbalancer"), verbosity: :debug
    execute *KAMAL.registry.login

    info "Stopping and removing #{KAMAL.loadbalancer.container_name} on #{host}, if running..."
    execute *KAMAL.loadbalancer.stop, raise_on_non_zero_exit: false
    execute *KAMAL.loadbalancer.remove_container

    if (lb_run = KAMAL.loadbalancer_config.run).secrets?
      execute *KAMAL.loadbalancer.ensure_proxy_directory
      upload! lb_run.secrets_io, lb_run.secrets_path, mode: "0600"
    else
      execute *KAMAL.loadbalancer.remove_proxy_secrets_file, raise_on_non_zero_exit: false
    end

    execute *KAMAL.loadbalancer.ensure_apps_config_directory
    Kamal::Cli::Proxy::LoadbalancerClaim.new(host, sshkit).claim_run_config(replace: true)
    execute *KAMAL.loadbalancer.run

    # kamal-proxy keeps its service state in the config volume, which the
    # replacement container re-mounts - every app's routes survive.
    services = capture_with_info(*KAMAL.loadbalancer.list).strip
    info "Services registered on the load balancer at #{host} after reboot:\n#{services}"
  end
end
