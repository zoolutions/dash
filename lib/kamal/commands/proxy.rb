class Kamal::Commands::Proxy < Kamal::Commands::Base
  include Kamal::Commands::Proxy::CertTransfer

  delegate :argumentize, :optionize, to: Kamal::Utils
  attr_reader :proxy_run_config

  CONFIG_DIGEST_LABEL = "org.kamal.proxy-config-digest"

  def initialize(config, host:)
    super(config)
    @proxy_run_config = config.proxy_run(host)
  end

  def run(digest: nil, name: nil)
    if proxy_run_config
      docker \
        :run,
        "--name", name || container_name,
        *proxy_run_config.network_args,
        "--detach",
        "--restart", "unless-stopped",
        "--volume", "kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy",
        *config_digest_label_args(digest),
        *proxy_run_config.docker_options_args,
        *proxy_run_config.image,
        *proxy_run_config.run_command
    else
      pipe boot_config, xargs(docker_run(digest: digest))
    end
  end

  def start
    docker :container, :start, container_name
  end

  def stop(name: container_name, timeout: nil)
    docker :container, :stop, *("--time #{timeout}" if timeout), name
  end

  def start_or_run(digest: nil)
    combine start, run(digest: digest), by: "||"
  end

  def info
    docker :ps, "--filter", "'name=^#{container_name}$'"
  end

  def version
    pipe \
      docker(:inspect, container_name, "--format '{{.Config.Image}}'"),
      [ :awk, "-F:", "'{print \$NF}'" ]
  end

  def config_digest
    docker :inspect, container_name, "--format", "'{{ index .Config.Labels \"#{CONFIG_DIGEST_LABEL}\" }}'"
  end

  def container_id(only_running: false)
    container_id_for(container_name: container_name, only_running: only_running)
  end

  def pull
    if proxy_run_config
      docker :pull, proxy_run_config.image
    else
      docker :pull, "#{substitute(read_image)}:#{substitute(read_image_version)}"
    end
  end

  def list(name: container_name, json: false)
    docker :exec, name, "kamal-proxy", :list, *("--json" if json)
  end

  def cache_stats(count: false, json: false)
    docker :exec, container_name, "kamal-proxy", :cache, :stats, *optionize({ count: count || nil, json: json || nil }.compact)
  end

  def cache_purge(service, path_prefix: nil)
    docker :exec, container_name, "kamal-proxy", :cache, :purge, service, *optionize({ "path-prefix": path_prefix }.compact)
  end

  # One mount destination per line - what the running container was actually
  # booted with, as opposed to what the current configuration would mount.
  def mount_destinations
    docker :inspect, container_name, "--format", "'{{range .Mounts}}{{println .Destination}}{{end}}'"
  end

  # Zero-downtime handoff commands (proxy/run port_holder mode)

  def port_holder?
    proxy_run_config&.port_holder? || false
  end

  def next_container_name
    "#{container_name}-next"
  end

  def run_holder
    docker \
      :run,
      "--name", proxy_run_config.holder_container_name,
      "--network", "kamal",
      "--detach",
      "--restart", "unless-stopped",
      *proxy_run_config.holder_docker_args,
      *proxy_run_config.image,
      "kamal-proxy", "hold"
  end

  def start_holder_or_run
    combine docker(:container, :start, proxy_run_config.holder_container_name), run_holder, by: "||"
  end

  def holder_container_id
    container_id_for(container_name: proxy_run_config.holder_container_name, only_running: true)
  end

  # Cancel the restart policy before draining: drain makes the proxy exit on
  # its own, which - unlike `docker stop` - an active restart policy would undo.
  def disable_restart
    docker :update, "--restart=no", container_name
  end

  def drain(timeout: nil)
    docker :exec, container_name, "kamal-proxy", :drain, *("--drain-timeout=#{timeout}s" if timeout)
  end

  def wait_for_exit(name: container_name)
    docker :wait, name
  end

  def remove_stopped_container(name: container_name)
    docker :container, :rm, name
  end

  def promote_next_container
    docker :container, :rename, next_container_name, container_name
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

  def domains(subcommand)
    docker :exec, container_name, "kamal-proxy", "domains", subcommand
  end

  def remove_container
    docker :container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=kamal-proxy"
  end

  def remove_image
    docker :image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=kamal-proxy"
  end

  def cleanup_traefik
    chain \
      docker(:container, :stop, "traefik"),
      combine(
        docker(:container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=Traefik"),
        docker(:image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=Traefik")
      )
  end

  def ensure_proxy_directory
    make_directory config.proxy_boot.host_directory
  end

  def remove_proxy_directory
    remove_directory config.proxy_boot.host_directory
  end

  def ensure_apps_config_directory
    make_directory config.proxy_boot.apps_directory
  end

  # Static path rather than proxy_run_config.secrets_path: the file must be
  # removable precisely when the run config (or its secrets) is gone.
  def remove_proxy_secrets_file
    remove_file File.join(config.proxy_boot.host_directory, Kamal::Configuration::Proxy::Run::SECRETS_FILENAME)
  end

  def boot_config
    [ :echo, "#{substitute(read_boot_options)} #{substitute(read_image)}:#{substitute(read_image_version)} #{substitute(read_run_command)}" ]
  end

  def read_boot_options
    read_file(config.proxy_boot.options_file, default: config.proxy_boot.default_boot_options.join(" "))
  end

  def read_image
    read_file(config.proxy_boot.image_file, default: config.proxy_boot.image_default)
  end

  def read_image_version
    read_file(config.proxy_boot.image_version_file, default: Kamal::Configuration::Proxy::Run::MINIMUM_VERSION)
  end

  def read_run_command
    read_file(config.proxy_boot.run_command_file)
  end

  def reset_boot_options
    remove_file config.proxy_boot.options_file
  end

  def reset_image
    remove_file config.proxy_boot.image_file
  end

  def reset_image_version
    remove_file config.proxy_boot.image_version_file
  end

  def reset_run_command
    remove_file config.proxy_boot.run_command_file
  end

  def loadbalancer
    @loadbalancer ||= Kamal::Commands::Loadbalancer.new(config, loadbalancer_config: KAMAL.loadbalancer_config)
  end

  private
    def container_name
      config.proxy_boot.container_name
    end

    def cert_store_volume_args
      [ "--volume", "kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy" ]
    end

    # Same fallback as #pull: without a run config the image comes from the
    # legacy boot config files on the host.
    def one_off_image
      if proxy_run_config
        [ proxy_run_config.image ]
      else
        [ "#{substitute(read_image)}:#{substitute(read_image_version)}" ]
      end
    end

    def config_digest_label_args(digest)
      [ "--label", "#{CONFIG_DIGEST_LABEL}=#{digest}" ] if digest
    end

    def docker_run(digest: nil)
      docker \
        :run,
        "--name", container_name,
        "--network", "kamal",
        "--detach",
        "--restart", "unless-stopped",
        "--volume", "kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy",
        *config_digest_label_args(digest),
        *config.proxy_boot.apps_volume.docker_args
    end
end
