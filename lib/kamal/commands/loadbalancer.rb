class Kamal::Commands::Loadbalancer < Kamal::Commands::Base
  include Kamal::Commands::Proxy::CertTransfer

  delegate :argumentize, :optionize, to: Kamal::Utils

  attr_reader :loadbalancer_config

  def initialize(config, loadbalancer_config: nil)
    super(config)
    @loadbalancer_config = loadbalancer_config
  end

  def run
    docker \
      :run,
      "--name", container_name,
      "--network", "kamal",
      "--detach",
      "--restart", "unless-stopped",
      "--label", label,
      "--label", "#{Kamal::Commands::Proxy::CONFIG_DIGEST_LABEL}=#{loadbalancer_config.run_config_digest}",
      *config_volume,
      *run_args,
      *loadbalancer_config.run.image,
      *loadbalancer_config.run.run_command
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

  def list(json: false)
    docker :exec, container_name, "kamal-proxy", :list, *("--json" if json)
  end

  # Cache policy is edge-only under load balancing (see the layering contract),
  # so the cache admin surface lives here - registered under the bare service
  # name, unlike the per-role services on the proxy hosts.
  def cache_stats(count: false, json: false)
    docker :exec, container_name, "kamal-proxy", :cache, :stats, *optionize({ count: count || nil, json: json || nil }.compact)
  end

  def cache_purge(service, path_prefix: nil)
    docker :exec, container_name, "kamal-proxy", :cache, :purge, service, *optionize({ "path-prefix": path_prefix }.compact)
  end

  def config_digest
    docker :inspect, container_name, "--format", "'{{ index .Config.Labels \"#{Kamal::Commands::Proxy::CONFIG_DIGEST_LABEL}\" }}'"
  end

  def container_id(only_running: false)
    container_id_for(container_name: container_name, only_running: only_running)
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

  # Where the proxy secrets env file lands (see Proxy::Run#secrets_path) -
  # the same .kamal/proxy directory the per-app proxy hosts use.
  def ensure_proxy_directory
    make_directory loadbalancer_config.run.host_directory
  end

  def remove_proxy_secrets_file
    remove_file loadbalancer_config.run.secrets_path
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

    # kamal-proxy keeps its state under /home/kamal-proxy/.config/kamal-proxy
    # whichever host it runs on - only the volume name differs, so a dedicated
    # load balancer and a shared proxy host never fight over the same volume.
    # (The apps-config mount comes with run_args, via the proxy's run surface.)
    def config_volume
      if on_proxy_host?
        [ "--volume", "kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy" ]
      else
        [ "--volume", "kamal-loadbalancer-config:/home/kamal-proxy/.config/kamal-proxy" ]
      end
    end

    # The certificate store lives in whichever config volume this loadbalancer
    # actually mounts — the shared kamal-proxy one on a proxy host.
    def cert_store_volume_args
      config_volume
    end

    def one_off_image
      [ loadbalancer_config.run.image ]
    end
end
