class Kamal::Cli::Proxy::Reboot
  READY_TIMEOUT = 30

  attr_reader :host, :sshkit
  delegate :execute, :capture_with_info, :info, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    execute *KAMAL.auditor.record("Rebooted proxy"), verbosity: :debug
    execute *KAMAL.registry.login

    pull_image
    replace_container
    wait_until_ready
    re_register_services
    verify_services
  end

  private
    def proxy
      @proxy ||= KAMAL.proxy(host)
    end

    def drift
      @drift ||= Kamal::Cli::Proxy::Drift.new(host, sshkit)
    end

    # Pull before stopping the old container: a registry outage or rate limit
    # can then no longer strand the host with no proxy at all.
    def pull_image
      info "Pulling kamal-proxy image on #{host}..."
      execute *proxy.pull
    end

    def replace_container
      info "Stopping and removing kamal-proxy on #{host}, if running..."
      execute *proxy.stop(timeout: KAMAL.config.drain_timeout + 10), raise_on_non_zero_exit: false
      execute *proxy.remove_container
      execute *proxy.ensure_proxy_directory
      execute *proxy.ensure_apps_config_directory

      execute *proxy.run(digest: drift.expected_digest)
    end

    def wait_until_ready
      deadline = Time.now + READY_TIMEOUT

      begin
        capture_with_info(*proxy.list, verbosity: :debug)
      rescue SSHKit::Command::Failed
        raise Kamal::Cli::BootError, "kamal-proxy on #{host} did not become ready within #{READY_TIMEOUT} seconds" if Time.now >= deadline
        sleep 0.5
        retry
      end
    end

    # Re-register this app's services rather than relying solely on the
    # proxy's own state restore — a proxy that came back with missing routes
    # would otherwise 404 until the next deploy.
    def re_register_services
      @registered_services = []

      KAMAL.roles_on(host).select(&:running_proxy?).each do |role|
        app = KAMAL.app(role: role, host: host)

        version = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false).strip.presence
        next unless version

        endpoint = capture_with_info(*app.container_id_for_version(version, only_running: true), raise_on_non_zero_exit: false).strip.presence
        next unless endpoint

        info "Re-registering #{role.container_prefix} with kamal-proxy on #{host}..."
        execute *app.deploy(target: endpoint)
        @registered_services << role.container_prefix
      end

      KAMAL.config.accessories.select(&:running_proxy?).each do |accessory_config|
        next unless accessory_config.hosts.include?(host.to_s)

        accessory = KAMAL.accessory(accessory_config.name)
        target = capture_with_info(*accessory.container_id_for(container_name: accessory_config.service_name, only_running: true), raise_on_non_zero_exit: false).strip.presence
        next unless target

        info "Re-registering #{accessory_config.service_name} with kamal-proxy on #{host}..."
        execute *accessory.deploy(target: target)
        @registered_services << accessory_config.service_name
      end
    end

    def verify_services
      return if @registered_services.empty?

      listing = capture_with_info(*proxy.list)
      missing = @registered_services.reject { |name| listing.include?(name) }

      if missing.any?
        raise Kamal::Cli::BootError, "kamal-proxy on #{host} is missing services after reboot: #{missing.join(", ")}"
      end
    end
end
