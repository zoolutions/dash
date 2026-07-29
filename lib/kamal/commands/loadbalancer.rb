class Kamal::Commands::Loadbalancer < Kamal::Commands::Base
  delegate :argumentize, :optionize, to: Kamal::Utils

  attr_reader :loadbalancer_config

  def initialize(config, loadbalancer_config: nil)
    super(config)
    @loadbalancer_config = loadbalancer_config
  end

  def run
    pipe \
      [ :echo, proxy_image ],
      xargs(docker(:run,
        "--name", container_name,
        "--network", "kamal",
        "--detach",
        "--restart", "unless-stopped",
        "--label", label,
        "--label", "#{Kamal::Commands::Proxy::CONFIG_DIGEST_LABEL}=#{loadbalancer_config.run_config_digest}",
        *run_args,
        *volume_mounts))
  end

  def start
    docker :container, :start, container_name
  end

  def stop(name: container_name)
    docker :container, :stop, name
  end

  def start_or_run
    combine start, run, by: "||"
  end

  def deploy(targets: [])
    docker :exec, container_name, "kamal-proxy", "deploy", loadbalancer_config.config.service,
      *loadbalancer_config.deploy_command_args(targets: targets)
  end

  def domains(subcommand)
    docker :exec, container_name, "kamal-proxy", "domains", subcommand
  end

  def list
    docker :exec, container_name, "kamal-proxy", :list
  end

  def config_digest
    docker :inspect, container_name, "--format", "'{{ index .Config.Labels \"#{Kamal::Commands::Proxy::CONFIG_DIGEST_LABEL}\" }}'"
  end

  def info
    docker :ps, "--filter", "'name=^#{container_name}$'"
  end

  def version
    pipe \
      docker(:inspect, container_name, "--format '{{.Config.Image}}'"),
      [ :cut, "-d:", "-f2" ]
  end

  def logs(timestamps: true, since: nil, lines: nil, grep: nil, grep_options: nil)
    pipe \
      docker(:logs, container_name, ("--since #{since}" if since), ("--tail #{lines}" if lines), ("--timestamps" if timestamps), "2>&1"),
      ("grep '#{grep}'#{" #{grep_options}" if grep_options}" if grep)
  end

  def follow_logs(host:, timestamps: true, grep: nil, grep_options: nil)
    run_over_ssh pipe(
      docker(:logs, container_name, ("--timestamps" if timestamps), "--tail", "10", "--follow", "2>&1"),
      (%(grep "#{grep}"#{" #{grep_options}" if grep_options}) if grep)
    ).join(" "), host: host
  end

  # Prune by the label the container was actually created with - on a shared
  # proxy host that is the kamal-proxy title, and pruning by the loadbalancer
  # title would leave the container behind for `run` to collide with.
  def remove_container
    docker :container, :prune, "--force", "--filter", "label=#{label}"
  end

  # Image label filters match labels baked into the image, and the load balancer
  # runs the kamal-proxy image whichever host it sits on.
  def remove_image
    docker :image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=kamal-proxy"
  end

  def ensure_directory
    make_directory loadbalancer_config.directory
  end

  def ensure_apps_config_directory
    make_directory config.proxy_boot.apps_directory
  end

  def ensure_services_directory
    make_directory loadbalancer_config.services_directory
  end

  def read_service_owner
    read_file loadbalancer_config.service_owner_file
  end

  def read_run_config_record
    read_file loadbalancer_config.run_config_file
  end

  def remove_directory
    super(loadbalancer_config.directory)
  end

  def container_name
    loadbalancer_config.container_name
  end

  private
    def run_args
      loadbalancer_config.run_args
    end

    def proxy_image
      [
        loadbalancer_config.config.proxy_boot.image_default,
        Kamal::Configuration::Proxy::Run::MINIMUM_VERSION
      ].join(":")
    end

    def on_proxy_host?
      loadbalancer_config.on_proxy_host?
    end

    def label
      if on_proxy_host?
        "org.opencontainers.image.title=kamal-proxy"
      else
        "org.opencontainers.image.title=kamal-loadbalancer"
      end
    end

    def volume_mounts
      if on_proxy_host?
        # When on a proxy host, use same volume mounts as proxy for app deployments
        [
          "--volume", "kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy",
          "--volume", "$PWD/#{config.proxy_boot.apps_directory}:/home/kamal-proxy/.apps-config"
        ]
      else
        [
          "--volume", "kamal-loadbalancer-config:/home/kamal-loadbalancer/.config/kamal-loadbalancer"
        ]
      end
    end
end
