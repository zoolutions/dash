require "shellwords"

class Dash::Commands::Accessory < Dash::Commands::Base
  include Proxy

  attr_reader :accessory_config
  delegate :service_name, :image, :hosts, :port, :files, :directories, :cmd,
           :network_args, :publish_args, :env_args, :volume_args, :label_args, :option_args,
           :restart_policy, :secrets_io, :secrets_path, :env_directory, :proxy, :running_proxy?, :registry,
           to: :accessory_config

  def initialize(config, name:)
    super(config)
    @accessory_config = config.accessory(name)
  end

  def run(host: nil)
    docker :run,
      "--name", service_name,
      "--detach",
      "--restart", restart_policy,
      *network_args,
      *config.logging_args,
      *publish_args,
      *([ "--env", "DASH_HOST=\"#{host}\"", "--env", "KAMAL_HOST=\"#{host}\"" ] if host),
      *env_args,
      *volume_args,
      *label_args,
      *option_args,
      image,
      cmd
  end

  def start
    docker :container, :start, service_name
  end

  def stop
    docker :container, :stop, service_name
  end

  # The accessory's container as `docker ps` JSON, running or not.
  def list_containers_json
    docker :ps, "--all", *service_filter, "--format", "'{{json .}}'"
  end

  # Same shape as Commands::App#stats_json: the labels, the separator, then `docker stats`
  # behind `xargs -r`, which keeps an accessory that is not running from reporting every
  # container on the host.
  def stats_json
    filters = [ *service_filter, *Dash::Commands::App::ACTIVE_DOCKER_STATUSES.flat_map { |status| [ "--filter", "status=#{status}" ] } ]

    chain \
      docker(:ps, *filters, "--format", "'{{json .}}'"),
      [ :echo, SECTION_SEPARATOR ],
      pipe(docker(:ps, "--quiet", *filters), [ :xargs, "-r", :docker, :stats, "--no-stream", "--format", "'{{json .}}'" ])
  end

  def info(all: false, quiet: false)
    docker :ps, *("-a" if all), *("-q" if quiet), *service_filter
  end

  def logs(timestamps: true, since: nil, lines: nil, grep: nil, grep_options: nil)
    pipe \
      docker(:logs, service_name, (" --since #{since.to_s.shellescape}" if since), (" --tail #{Integer(lines.to_s, 10)}" if lines), ("--timestamps" if timestamps), "2>&1"),
      ("grep #{Dash::Utils.single_quote(grep)}#{" #{grep_options}" if grep_options}" if grep)
  end

  def follow_logs(timestamps: true, grep: nil, grep_options: nil)
    run_over_ssh \
      pipe \
        docker(:logs, service_name, ("--timestamps" if timestamps), "--tail", "10", "--follow", "2>&1"),
        (%(grep "#{grep}"#{" #{grep_options}" if grep_options}) if grep)
  end

  def execute_in_existing_container(*command, interactive: false)
    docker :exec,
      (docker_interactive_args if interactive),
      service_name,
      *command
  end

  def execute_in_new_container(*command, interactive: false)
    docker :run,
      (docker_interactive_args if interactive),
      "--rm",
      *network_args,
      *env_args,
      *volume_args,
      *option_args,
      image,
      *command
  end

  def execute_in_existing_container_over_ssh(*command)
    run_over_ssh execute_in_existing_container(*command, interactive: true)
  end

  def execute_in_new_container_over_ssh(*command)
    run_over_ssh execute_in_new_container(*command, interactive: true)
  end

  def run_over_ssh(command)
    super command, host: hosts.first
  end

  def ensure_local_file_present(local_file)
    if !local_file.is_a?(StringIO) && !Pathname.new(local_file).exist?
      raise "Missing file: #{local_file}"
    end
  end

  def pull_image
    docker :image, :pull, image
  end

  def remove_service_directory
    [ :rm, "-rf", service_name ]
  end

  def remove_container
    docker :container, :prune, "--force", *service_filter
  end

  def remove_image
    docker :image, :rm, "--force", image
  end

  def ensure_env_directory
    make_directory env_directory
  end

  private
    def service_filter
      [ "--filter", "label=service=#{service_name}" ]
    end
end
