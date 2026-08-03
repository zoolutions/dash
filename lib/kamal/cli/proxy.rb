class Kamal::Cli::Proxy < Kamal::Cli::Base
  desc "boot", "Boot proxy on servers"
  def boot
    modify(lock: true) do
      on(KAMAL.hosts) do |host|
        execute *KAMAL.docker.create_network
      rescue SSHKit::Command::Failed => e
        raise unless e.message.include?("already exists")
      end

      # Skip proxy on loadbalancer host - the loadbalancer will handle it
      proxy_hosts = KAMAL.proxy_hosts
      if KAMAL.config.proxy.loadbalancer_on_proxy_host?
        proxy_hosts = proxy_hosts - [ KAMAL.config.proxy.effective_loadbalancer ]
      end

      drifted_hosts = Concurrent::Array.new
      stale_hosts = Concurrent::Array.new
      auto_reboot = KAMAL.config.proxy.reboot_on_deploy?

      on(proxy_hosts) do |host|
        execute *KAMAL.registry.login

        proxy = KAMAL.proxy(host)
        drift = Kamal::Cli::Proxy::Drift.new(host, self)

        if drift.drifted? && auto_reboot
          # Leave the old proxy serving until its serial reboot slot below.
          drifted_hosts << host.to_s
        else
          stale_hosts << host.to_s if drift.drifted?

          version = capture_with_info(*proxy.version).strip.presence

          if version && Kamal::Utils.older_version?(version, Kamal::Configuration::Proxy::Run::MINIMUM_VERSION)
            raise "kamal-proxy version #{version} is too old, run `kamal proxy reboot` in order to update to at least #{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}"
          end

          if (run_config = proxy.proxy_run_config)&.secrets?
            execute *proxy.ensure_proxy_directory
            upload! run_config.secrets_io, run_config.secrets_path, mode: "0600"
          else
            # A host keeps no secrets it no longer needs.
            execute *proxy.remove_proxy_secrets_file, raise_on_non_zero_exit: false
          end

          execute *proxy.ensure_apps_config_directory
          execute *proxy.start_or_run(digest: drift.expected_digest)
        end
      end

      if stale_hosts.any?
        say "kamal-proxy on #{stale_hosts.sort.join(", ")} is running with a configuration that no longer matches the deploy config. " \
            "Automatic reboot is disabled (proxy: reboot_on_deploy: false) - run `kamal proxy reboot` to apply the new configuration.", :yellow
      end

      drifted_hosts.sort.each do |host|
        say "kamal-proxy configuration changed, rebooting on #{host}...", :magenta
        run_hook "pre-proxy-reboot", hosts: host
        on(host) do |h|
          Kamal::Cli::Proxy::Reboot.new(h, self).run
        end
        run_hook "post-proxy-reboot", hosts: host
      end

      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          info "Starting loadbalancer on #{host}..."
          execute *KAMAL.registry.login

          # The load balancer terminates TLS and owns the cache, so its host
          # needs the proxy secrets (acme credentials, cache store) just like
          # the proxy hosts do.
          if (lb_run = KAMAL.loadbalancer_config.run).secrets?
            execute *KAMAL.loadbalancer.ensure_proxy_directory
            upload! lb_run.secrets_io, lb_run.secrets_path, mode: "0600"
          else
            execute *KAMAL.loadbalancer.remove_proxy_secrets_file, raise_on_non_zero_exit: false
          end

          execute *KAMAL.loadbalancer.ensure_apps_config_directory

          # TLS terminates at the load balancer, so the TLS material the app
          # hosts get - custom certificates and the mTLS client CA - must
          # reach this host too; the LB container reads it through the same
          # apps-config mount the per-host proxies use.
          KAMAL.config.roles.select(&:running_proxy?).each do |role|
            Kamal::Cli::App::SslCertificates.new(host, role, self).run
          end

          Kamal::Cli::Proxy::LoadbalancerClaim.new(host, self).claim_run_config
          execute *KAMAL.loadbalancer.start_or_run
        end
      end
    end
  end

  desc "boot_config <set|get|reset>", "Manage kamal-proxy boot configuration"
  option :publish, type: :boolean, default: true, desc: "Publish the proxy ports on the host"
  option :publish_host_ip, type: :string, repeatable: true, default: nil, desc: "Host IP address to bind HTTP/HTTPS traffic to. Defaults to all interfaces"
  option :http_port, type: :numeric, default: Kamal::Configuration::Proxy::Run::DEFAULT_HTTP_PORT, desc: "HTTP port to publish on the host"
  option :https_port, type: :numeric, default: Kamal::Configuration::Proxy::Run::DEFAULT_HTTPS_PORT, desc: "HTTPS port to publish on the host"
  option :log_max_size, type: :string, default: Kamal::Configuration::Proxy::Run::DEFAULT_LOG_MAX_SIZE, desc: "Max size of proxy logs"
  option :registry, type: :string, default: nil, desc: "Registry to use for the proxy image"
  option :repository, type: :string, default: nil, desc: "Repository for the proxy image"
  option :image_version, type: :string, default: nil, desc: "Version of the proxy to run"
  option :metrics_port, type: :numeric, default: nil, desc: "Port to report prometheus metrics on"
  option :debug, type: :boolean, default: false, desc: "Whether to run the proxy in debug mode"
  option :docker_options, type: :array, default: [], desc: "Docker options to pass to the proxy container", banner: "option=value option2=value2"
  def boot_config(subcommand)
    say "The proxy boot_config command is deprecated - set the config in the deploy YAML at proxy/run instead", :yellow
    proxy_boot_config = KAMAL.config.proxy_boot

    case subcommand
    when "set"
      boot_options = [
        *(proxy_boot_config.publish_args(options[:http_port], options[:https_port], options[:publish_host_ip]) if options[:publish]),
        *(proxy_boot_config.logging_args(options[:log_max_size])),
        *("--expose=#{options[:metrics_port]}" if options[:metrics_port]),
        *options[:docker_options].map { |option| "--#{option}" }
      ]

      image = [
        options[:registry].presence,
        options[:repository].presence || proxy_boot_config.repository_name,
        proxy_boot_config.image_name
      ].compact.join("/")

      image_version = options[:image_version]

      run_command_options = { debug: options[:debug] || nil, "metrics-port": options[:metrics_port] }.compact
      run_command = "kamal-proxy run #{Kamal::Utils.optionize(run_command_options).join(" ")}" if run_command_options.any?

      on(KAMAL.proxy_hosts) do |host|
        proxy = KAMAL.proxy(host)
        execute(*proxy.ensure_proxy_directory)
        if boot_options != proxy_boot_config.default_boot_options
          upload! StringIO.new(boot_options.join(" ")), proxy_boot_config.options_file
        else
          execute *proxy.reset_boot_options, raise_on_non_zero_exit: false
        end

        if image != proxy_boot_config.image_default
          upload! StringIO.new(image), proxy_boot_config.image_file
        else
          execute *proxy.reset_image, raise_on_non_zero_exit: false
        end

        if image_version
          upload! StringIO.new(image_version), proxy_boot_config.image_version_file
        else
          execute *proxy.reset_image_version, raise_on_non_zero_exit: false
        end

        if run_command
          upload! StringIO.new(run_command), proxy_boot_config.run_command_file
        else
          execute *proxy.reset_run_command, raise_on_non_zero_exit: false
        end
      end
    when "get"

      on(KAMAL.proxy_hosts) do |host|
        puts "Host #{host}: #{capture_with_info(*KAMAL.proxy(host).boot_config)}"
      end
    when "reset"
      on(KAMAL.proxy_hosts) do |host|
        proxy = KAMAL.proxy(host)
        execute *proxy.reset_boot_options, raise_on_non_zero_exit: false
        execute *proxy.reset_image, raise_on_non_zero_exit: false
        execute *proxy.reset_image_version, raise_on_non_zero_exit: false
        execute *proxy.reset_run_command, raise_on_non_zero_exit: false
      end
    else
      raise ArgumentError, "Unknown boot_config subcommand #{subcommand}"
    end
  end

  desc "reboot", "Reboot proxy on servers (stop container, remove container, start new container)"
  option :rolling, type: :boolean, default: false, desc: "Reboot proxy on hosts in sequence, rather than in parallel"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  def reboot
    confirming "This will cause a brief outage on each host. Are you sure?" do
      modify(lock: true) do
        # Skip proxy on loadbalancer host - it will be handled by loadbalancer reboot
        proxy_hosts = KAMAL.proxy_hosts
        if KAMAL.config.proxy.loadbalancer_on_proxy_host?
          proxy_hosts = proxy_hosts - [ KAMAL.config.proxy.effective_loadbalancer ]
        end

        host_groups = options[:rolling] ? proxy_hosts : [ proxy_hosts ]
        host_groups.each do |hosts|
          next if Array(hosts).empty?

          host_list = Array(hosts).join(",")
          run_hook "pre-proxy-reboot", hosts: host_list
          on(hosts) do |host|
            info "Rebooting kamal-proxy on #{host}..."
            Kamal::Cli::Proxy::Reboot.new(host, self).run
          end
          run_hook "post-proxy-reboot", hosts: host_list
        end

        if KAMAL.config.proxy.load_balancing?
          lb_host = KAMAL.config.proxy.effective_loadbalancer
          run_hook "pre-loadbalancer-reboot", hosts: lb_host

          on(lb_host) do |host|
            execute *KAMAL.auditor.record("Rebooted loadbalancer"), verbosity: :debug
            execute *KAMAL.registry.login

            info "Stopping and removing #{KAMAL.loadbalancer.container_name} on #{host}, if running..."
            execute *KAMAL.loadbalancer.stop, raise_on_non_zero_exit: false
            execute *KAMAL.loadbalancer.remove_container

            # Same as boot: the replacement container's --env-file must find
            # current secrets, not whatever an earlier boot left behind.
            if (lb_run = KAMAL.loadbalancer_config.run).secrets?
              execute *KAMAL.loadbalancer.ensure_proxy_directory
              upload! lb_run.secrets_io, lb_run.secrets_path, mode: "0600"
            else
              execute *KAMAL.loadbalancer.remove_proxy_secrets_file, raise_on_non_zero_exit: false
            end

            execute *KAMAL.loadbalancer.ensure_apps_config_directory

            Kamal::Cli::Proxy::LoadbalancerClaim.new(host, self).claim_run_config(replace: true)
            execute *KAMAL.loadbalancer.run

            # kamal-proxy keeps its service state in the config volume, which the
            # replacement container re-mounts - every app's routes survive.
            services = capture_with_info(*KAMAL.loadbalancer.list).strip
            info "Services registered on the load balancer at #{host} after reboot:\n#{services}"
          end

          run_hook "post-loadbalancer-reboot", hosts: lb_host
        end
      end
    end
  end

  desc "upgrade", "Upgrade to kamal-proxy on servers (stop container, remove container, start new container, reboot app)", hide: true
  option :rolling, type: :boolean, default: false, desc: "Reboot proxy on hosts in sequence, rather than in parallel"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  def upgrade
    invoke_options = { "version" => KAMAL.config.latest_tag }.merge(options)

    confirming "This will cause a brief outage on each host. Are you sure?" do
      host_groups = options[:rolling] ? KAMAL.hosts : [ KAMAL.hosts ]
      host_groups.each do |hosts|
        host_list = Array(hosts).join(",")
        say "Upgrading proxy on #{host_list}...", :magenta
        run_hook "pre-proxy-reboot", hosts: host_list
        on(hosts) do |host|
          proxy = KAMAL.proxy(host)
          execute *KAMAL.auditor.record("Rebooted proxy"), verbosity: :debug
          execute *KAMAL.registry.login

          info "Stopping and removing Traefik on #{host}, if running..."
          execute *proxy.cleanup_traefik

          info "Stopping and removing kamal-proxy on #{host}, if running..."
          execute *proxy.stop, raise_on_non_zero_exit: false
          execute *proxy.remove_container
          execute *proxy.remove_image
        end

        KAMAL.with_specific_hosts(hosts) do
          invoke "kamal:cli:proxy:boot", [], invoke_options
          reset_invocation(Kamal::Cli::Proxy)
          invoke "kamal:cli:app:boot", [], invoke_options
          reset_invocation(Kamal::Cli::App)
          invoke "kamal:cli:prune:all", [], invoke_options
          reset_invocation(Kamal::Cli::Prune)
        end

        run_hook "post-proxy-reboot", hosts: host_list
        say "Upgraded proxy on #{host_list}", :magenta
      end
    end
  end

  desc "start", "Start existing proxy container on servers"
  def start
    modify(lock: true) do
      on(KAMAL.proxy_hosts) do |host|
        execute *KAMAL.auditor.record("Started proxy"), verbosity: :debug
        execute *KAMAL.proxy(host).start
      end

      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do
          execute *KAMAL.auditor.record("Started loadbalancer"), verbosity: :debug
          execute *KAMAL.loadbalancer.start, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "stop", "Stop existing proxy container on servers"
  def stop
    modify(lock: true) do
      on(KAMAL.proxy_hosts) do |host|
        execute *KAMAL.auditor.record("Stopped proxy"), verbosity: :debug
        execute *KAMAL.proxy(host).stop, raise_on_non_zero_exit: false
      end

      # `docker container prune` only collects stopped containers, so leaving the
      # loadbalancer running would also leave `kamal proxy remove` unable to
      # remove it.
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do
          execute *KAMAL.auditor.record("Stopped loadbalancer"), verbosity: :debug
          execute *KAMAL.loadbalancer.stop, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "restart", "Restart existing proxy container on servers"
  def restart
    modify(lock: true) do
      stop
      start
    end
  end

  desc "details", "Show details about proxy container from servers"
  def details
    quiet = options[:quiet]
    on(KAMAL.proxy_hosts) { |host| puts_by_host host, capture_with_info(*KAMAL.proxy(host).info), type: "Proxy", quiet: quiet }

    if KAMAL.config.proxy.load_balancing?
      on(KAMAL.config.proxy.effective_loadbalancer) do |host|
        puts_by_host host, capture_with_info(*KAMAL.loadbalancer.info), type: "Loadbalancer"
      end
    end
  end

  desc "logs", "Show log lines from proxy on servers"
  option :since, aliases: "-s", desc: "Show logs since timestamp (e.g. 2013-01-02T13:23:37Z) or relative (e.g. 42m for 42 minutes)"
  option :lines, type: :numeric, aliases: "-n", desc: "Number of log lines to pull from each server"
  option :grep, aliases: "-g", desc: "Show lines with grep match only (use this to fetch specific requests by id)"
  option :follow, aliases: "-f", desc: "Follow logs on primary server (or specific host set by --hosts)"
  option :skip_timestamps, type: :boolean, aliases: "-T", desc: "Skip appending timestamps to logging output"
  def logs
    grep = options[:grep]
    timestamps = !options[:skip_timestamps]

    if options[:follow]
      run_locally do
        proxy = KAMAL.proxy(KAMAL.primary_host)
        info "Following logs on #{KAMAL.primary_host}..."
        info proxy.follow_logs(host: KAMAL.primary_host, timestamps: timestamps, grep: grep)
        exec proxy.follow_logs(host: KAMAL.primary_host, timestamps: timestamps, grep: grep)
      end
    else
      since = options[:since]
      lines = options[:lines].presence || ((since || grep) ? nil : 100) # Default to 100 lines if since or grep isn't set

      on(KAMAL.proxy_hosts) do |host|
        puts_by_host host, capture(*KAMAL.proxy(host).logs(timestamps: timestamps, since: since, lines: lines, grep: grep)), type: "Proxy"
      end
    end
  end

  desc "remove", "Remove proxy container and image from servers"
  option :force, type: :boolean, default: false, desc: "Force removing proxy when apps are still installed"
  def remove
    modify(lock: true) do
      if removal_allowed?(options[:force])
        stop
        remove_container
        remove_image
        remove_proxy_directory
      end
    end
  end

  desc "loadbalancer STATUS", "Manage the load balancer"
  def loadbalancer(status)
    case status
    when "info"
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          puts "Loadbalancer status on #{host}:"
          puts capture_with_info(*KAMAL.loadbalancer.info)
        end
      else
        puts "Load balancing is not configured"
      end
    when "start"
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          execute *KAMAL.registry.login
          execute *KAMAL.loadbalancer.start_or_run
        end
      else
        puts "Load balancing is not configured"
      end
    when "stop"
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          execute *KAMAL.loadbalancer.stop, raise_on_non_zero_exit: false
        end
      else
        puts "Load balancing is not configured"
      end
    when "logs"
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          puts_by_host host, capture(*KAMAL.loadbalancer.logs(timestamps: true)), type: "Loadbalancer"
        end
      else
        puts "Load balancing is not configured"
      end
    when "deploy"
      if KAMAL.config.proxy.load_balancing?
        targets = []
        KAMAL.config.roles.each do |role|
          next unless role.running_proxy?

          role.hosts.each do |host|
            targets << host
          end
        end

        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          Kamal::Cli::Proxy::LoadbalancerClaim.new(host, self).claim_service
          info "Deploying to loadbalancer on #{host} with targets: #{targets.join(', ')}"
          execute *KAMAL.loadbalancer.deploy(targets: targets)
        end
      else
        puts "Load balancing is not configured"
      end
    else
      puts "Unknown loadbalancer subcommand: #{status}. Available: info, start, stop, logs, deploy"
    end
  end

  desc "domains SUBCOMMAND", "Manage dynamic TLS domains (refresh, list, stats)"
  def domains(subcommand)
    case subcommand
    when "refresh", "list", "stats"
      # TLS terminates at the load balancer when load balancing, so the
      # dynamic domain set lives there rather than on the per-host proxies.
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do |host|
          puts_by_host host, capture_with_info(*KAMAL.loadbalancer.domains(subcommand)), type: "Loadbalancer"
        end
      else
        on(KAMAL.proxy_hosts) do |host|
          puts_by_host host, capture_with_info(*KAMAL.proxy(host).domains(subcommand)), type: "Proxy"
        end
      end
    else
      puts "Unknown domains subcommand: #{subcommand}. Available: refresh, list, stats"
    end
  end

  desc "remove_container", "Remove proxy container from servers", hide: true
  def remove_container
    modify(lock: true) do
      on(KAMAL.proxy_hosts) do
        execute *KAMAL.auditor.record("Removed proxy container"), verbosity: :debug
        execute *KAMAL.proxy(host).remove_container
      end

      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do
          execute *KAMAL.auditor.record("Removed loadbalancer container"), verbosity: :debug
          execute *KAMAL.loadbalancer.remove_container
        end
      end
    end
  end

  desc "remove_image", "Remove proxy image from servers", hide: true
  def remove_image
    modify(lock: true) do
      on(KAMAL.proxy_hosts) do
        execute *KAMAL.auditor.record("Removed proxy image"), verbosity: :debug
        execute *KAMAL.proxy(host).remove_image
      end

      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do
          execute *KAMAL.auditor.record("Removed loadbalancer image"), verbosity: :debug
          execute *KAMAL.loadbalancer.remove_image
        end
      end
    end
  end

  desc "remove_proxy_directory", "Remove the proxy directory from servers", hide: true
  def remove_proxy_directory
    modify(lock: true) do
      on(KAMAL.proxy_hosts) do
        execute *KAMAL.proxy(host).remove_proxy_directory, raise_on_non_zero_exit: false
      end

      # Otherwise the ownership registry outlives the load balancer and a later
      # boot would fail against an owner that no longer exists.
      if KAMAL.config.proxy.load_balancing?
        on(KAMAL.config.proxy.effective_loadbalancer) do
          execute *KAMAL.loadbalancer.remove_directory, raise_on_non_zero_exit: false
        end
      end
    end
  end

  private
    # A shared load balancer tier is the exact case this guard exists for, so it
    # has to cover the load balancer host too - `remove_container` and
    # `remove_image` both act on it.
    def removal_hosts
      hosts = KAMAL.proxy_hosts.to_a
      hosts |= [ KAMAL.config.proxy.effective_loadbalancer ] if KAMAL.config.proxy.load_balancing?
      hosts
    end

    def removal_allowed?(force)
      on(removal_hosts) do |host|
        app_count = capture_with_info(*KAMAL.server.app_directory_count).chomp.to_i
        raise "The are other applications installed on #{host}" if app_count > 0
      end

      true
    rescue SSHKit::Runner::ExecuteError => e
      raise unless e.message.include?("The are other applications installed on")

      if force
        say "Forcing, so removing the proxy, even though other apps are installed", :magenta
      else
        say "Not removing the proxy, as other apps are installed, ignore this check with kamal proxy remove --force", :magenta
      end

      force
    end
end
