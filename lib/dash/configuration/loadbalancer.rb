class Dash::Configuration::Loadbalancer < Dash::Configuration::Proxy
  CONTAINER_NAME = "load-balancer".freeze
  SHARED_CONTAINER_NAME = "kamal-proxy".freeze

  def self.validation_config_key
    "proxy"
  end

  def initialize(config:, proxy_config:, secrets:)
    super
  end

  # The load balancer fans a single service out to many targets, so unlike the
  # per-app proxy deploy (which takes one target) it takes the full list and
  # joins them into a single --target flag.
  #
  # Each target is a per-host proxy, reached on its published HTTP port
  # (run.http_port, default 80) - the only cross-host surface it exposes.
  # Never app_port: that is how a per-host proxy reaches the app container
  # inside its own docker network, and nothing listens on it across hosts.
  def deploy_command_args(targets:)
    target_arg = targets.map { |target| "#{target}:#{run.http_port}" }.join(",")
    optionize ({ target: target_arg }).merge(deploy_options), with: "="
  end

  # The hosts the load balancer forwards to: every host of every role that
  # runs a proxy. One source of truth for the deploy step and the reboot
  # re-registration, so their target lists cannot diverge.
  def target_hosts
    config.roles.select(&:running_proxy?).flat_map(&:hosts)
  end

  def directory
    File.join config.run_directory, "loadbalancer"
  end

  # The load balancer is a kamal-proxy container, so proxy/run applies to it
  # exactly as it does to the per-host proxies. Without a run block it still
  # needs the default surface (published ports, log rotation, the apps-config
  # mount and the run command) to boot from, so fall back to an empty config
  # rather than to nil.
  def run
    @run ||= Dash::Configuration::Proxy::Run.new(config, run_config: {})
  end

  # Docker options for the load balancer container: publish/logging/options
  # plus the mounts and env file the proxy's run surface brings along —
  # notably the secrets env file, without which the edge cannot issue
  # certificates even though it is the layer terminating TLS.
  #
  # The one holder-mode exception: port_holder suppresses publish_args on the
  # proxy hosts (the holder owns the ports there), but the load balancer has
  # no holder — its reboot path is stop->run — so it always publishes its own.
  def run_args
    [ *(run.publish_args if run.port_holder?), *run.docker_options_args ]
  end

  # Digest of what the load balancer container is booted with, so a second app
  # pointing at the same host can tell whether its proxy/run agrees with
  # whatever is already running there. Same composition as the proxy's own
  # drift digest: image, run command, docker options and the acme credential
  # names (their values deliberately stay out - see Proxy::Run#config_digest).
  def run_config_digest
    run.config_digest
  end

  # Kamal has no app identifier, so ownership of a service on a shared load
  # balancer is expressed as repository plus destination-qualified service name:
  # the repository separates two different apps, the destination separates two
  # deployments of one app. The load balancer registers services under the bare
  # service name, so both can collide.
  def owner_token
    [ config.service_and_destination, config.repository ].join(" ")
  end

  def run_config_record
    [ owner_token, run_config_digest ].join(" ")
  end

  def run_config_file
    File.join directory, "run_config"
  end

  def services_directory
    File.join directory, "services"
  end

  def service_owner_file
    File.join services_directory, config.service
  end

  def container_name
    on_proxy_host? ? SHARED_CONTAINER_NAME : CONTAINER_NAME
  end

  # When loadbalancer is on a proxy host, it takes over the proxy role
  def on_proxy_host?
    config.proxy_hosts.include?(config.proxy.effective_loadbalancer)
  end

  private
    # The edge half of the layering contract (see
    # Dash::Configuration::Proxy::DEPLOY_OPTION_DISPOSITIONS): the load
    # balancer applies the edge and shared concerns, and leaves the per-app
    # ones to the per-host proxies it forwards to.
    def retained_dispositions
      %i[ edge both ]
    end
end
