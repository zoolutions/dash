class Dash::Commands::Loadbalancer < Dash::Commands::Base
  include Dash::Commands::Proxy::CertTransfer

  delegate :argumentize, :optionize, to: Dash::Utils

  attr_reader :loadbalancer_config

  def initialize(config, loadbalancer_config: nil)
    super(config)
    @loadbalancer_config = loadbalancer_config
  end

  def run
    docker \
      :run,
      "--name", container_name,
      "--network", "dash",
      "--detach",
      "--restart", "unless-stopped",
      "--label", label,
      "--label", "#{Dash::Commands::Proxy::CONFIG_DIGEST_LABEL}=#{loadbalancer_config.run_config_digest}",
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
    docker :exec, container_name, "dash-proxy", "deploy", loadbalancer_config.config.service,
      *loadbalancer_config.deploy_command_args(targets: targets)
  end

  # `retry` takes a host, or --all; the rest take no arguments.
  def domains(subcommand, *args)
    docker :exec, container_name, "dash-proxy", "domains", subcommand, *args
  end

  def list(json: false)
    docker :exec, container_name, "dash-proxy", :list, *("--json" if json)
  end

  # Cache policy is edge-only under load balancing (see the layering contract),
  # so the cache admin surface lives here - registered under the bare service
  # name, unlike the per-role services on the proxy hosts.
  def cache_stats(count: false, json: false)
    docker :exec, container_name, "dash-proxy", :cache, :stats, *optionize({ count: count || nil, json: json || nil }.compact)
  end

  def cache_purge(service, path_prefix: nil)
    docker :exec, container_name, "dash-proxy", :cache, :purge, service, *optionize({ "path-prefix": path_prefix }.compact)
  end

  def config_digest
    docker :inspect, container_name, "--format", Dash::Commands::Proxy::CONFIG_DIGEST_FORMAT
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
  # proxy host that is the dash-proxy title, and pruning by the loadbalancer
  # title would leave the container behind for `run` to collide with. Both the
  # current and the pre-rename title are pruned, so a container created before
  # the rename is not left behind to collide either.
  def remove_container
    combine \
      prune_containers_titled(image_title),
      prune_containers_titled(legacy_image_title)
  end

  # Image label filters match labels baked into the image, and the load balancer
  # runs the dash-proxy image whichever host it sits on. Both titles are matched
  # so a host still carrying a pre-rename image is cleaned up too; Docker ANDs
  # multiple `--filter label=` values, so that is two commands.
  def remove_image
    combine \
      prune_images_titled(Dash::Configuration::Proxy::IMAGE_TITLE),
      prune_images_titled(Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE)
  end

  def ensure_directory
    make_directory loadbalancer_config.directory
  end

  # Where the proxy secrets env file lands (see Proxy::Run#secrets_path) -
  # the same .dash/proxy directory the per-app proxy hosts use.
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

    # The full `key=value` the container is created with, so `--label #{label}`
    # stays correct. The prune helpers take a bare title instead.
    def label
      "org.opencontainers.image.title=#{image_title}"
    end

    def image_title
      if on_proxy_host?
        Dash::Configuration::Proxy::IMAGE_TITLE
      else
        Dash::Configuration::Proxy::LOADBALANCER_IMAGE_TITLE
      end
    end

    def legacy_image_title
      if on_proxy_host?
        Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE
      else
        Dash::Configuration::Proxy::LEGACY_LOADBALANCER_IMAGE_TITLE
      end
    end

    def prune_containers_titled(title)
      docker :container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    def prune_images_titled(title)
      docker :image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    # dash-proxy keeps its state under /home/dash-proxy/.config/dash-proxy
    # whichever host it runs on - only the volume name differs, so a dedicated
    # load balancer and a shared proxy host never fight over the same volume.
    # (The apps-config mount comes with run_args, via the proxy's run surface.)
    def config_volume
      if on_proxy_host?
        [ "--volume", "dash-proxy-config:/home/dash-proxy/.config/dash-proxy" ]
      else
        [ "--volume", "dash-loadbalancer-config:/home/dash-proxy/.config/dash-proxy" ]
      end
    end

    # The certificate store lives in whichever config volume this loadbalancer
    # actually mounts — the shared dash-proxy one on a proxy host.
    def cert_store_volume_args
      config_volume
    end

    def one_off_image
      [ loadbalancer_config.run.image ]
    end
end
