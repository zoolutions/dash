# Remote readiness checks for a single host, run inside an SSHKit backend.
#
# Every check rescues StandardError at its boundary: the doctor's contract is
# to report broken environments, not crash on them, and a failed connection can
# raise anything from Net::SSH errors to Errno and DNS resolution errors.
class Dash::Cli::Doctor::HostChecks
  attr_reader :host, :sshkit, :proxy_host
  delegate :execute, :capture_with_info, to: :sshkit

  def initialize(host, sshkit, proxy_host:)
    @host = host
    @sshkit = sshkit
    @proxy_host = proxy_host
  end

  def run
    checks = { ssh: ssh_check }

    if checks[:ssh].ok?
      checks[:docker] = docker_check
      checks[:registry] = registry_check
      checks.merge!(proxy_checks) if proxy_host
    end

    checks
  end

  private
    def result(check, status, detail)
      Dash::Cli::Doctor::Result.new(check, host, status, detail)
    end

    def ssh_check
      execute "true"
      result :ssh, :ok, "connected"
    rescue StandardError => e
      result :ssh, :fail, "#{e.class}: #{e.message}"
    end

    def docker_check
      if execute(*DASH.docker.running?, raise_on_non_zero_exit: false)
        result :docker, :ok, "docker is installed and running"
      else
        result :docker, :fail, "docker is not installed or not running (run `dash server bootstrap`)"
      end
    rescue StandardError => e
      result :docker, :fail, "#{e.class}: #{e.message}"
    end

    def registry_check
      return result(:registry, :ok, "local registry, no login required") if DASH.registry.local?

      if execute(*DASH.registry.login, raise_on_non_zero_exit: false)
        result :registry, :ok, "logged in to #{registry_name}"
      else
        result :registry, :fail, "docker login to #{registry_name} failed (check registry credentials)"
      end
    rescue StandardError => e
      result :registry, :fail, "#{e.class}: #{e.message}"
    end

    def proxy_checks
      version, version_error = capture_proxy_version
      # A host that has not been through the stage-3c rename is still running
      # kamal-proxy. Without asking about it too, the version check reports "not
      # running" and the ports check blames a foreign process for the ports that
      # container legitimately holds — failing the very deploy that migrates it.
      legacy_version = version.present? ? nil : capture_legacy_proxy_version

      {
        proxy_image: proxy_image_check,
        proxy_version: proxy_version_check(version, version_error, legacy_version),
        proxy_socket: proxy_socket_check(proxy_running: version.present?),
        ports: ports_check(proxy_running: version.present?, legacy_proxy_running: legacy_version.present?)
      }
    end

    def capture_proxy_version
      [ capture_with_info(*DASH.proxy(host).version).strip.presence, nil ]
    rescue StandardError => e
      [ nil, e ]
    end

    # Best-effort: a host with no legacy container simply reports nothing, and
    # any error here must not turn into a failing check of its own.
    def capture_legacy_proxy_version
      capture_with_info(*DASH.proxy(host).version(name: Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME)).strip.presence
    rescue StandardError
      nil
    end

    def proxy_image_check
      image = expected_proxy_image

      if execute(*DASH.docker.manifest_available?(image), raise_on_non_zero_exit: false)
        result :proxy_image, :ok, "#{image} manifest is fetchable"
      else
        result :proxy_image, :fail, "cannot fetch the manifest for #{image} (registry unreachable or unauthorized)"
      end
    rescue StandardError => e
      result :proxy_image, :fail, "#{e.class}: #{e.message}"
    end

    def proxy_version_check(version, error, legacy_version = nil)
      minimum = Dash::Configuration::Proxy::Run::MINIMUM_VERSION

      if error
        result :proxy_version, :warn, "could not determine the running version (#{error.message})"
      elsif version.nil? && legacy_version.present?
        result :proxy_version, :ok,
          "#{Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME} #{legacy_version} is running; it is renamed to " \
          "#{Dash::Configuration::Proxy::CONTAINER_NAME} on the next deploy, which briefly interrupts this host"
      elsif version.nil?
        result :proxy_version, :ok, "not running (will be started on deploy)"
      elsif Dash::Utils.older_version?(version, minimum)
        if deploy_reboots_proxy?
          result :proxy_version, :ok,
            "#{version} is older than the minimum #{minimum}; the next deploy reboots the proxy to update it"
        else
          result :proxy_version, :fail, "#{version} is older than the minimum #{minimum}, run `dash proxy reboot` to update"
        end
      else
        result :proxy_version, :ok, "#{version} (minimum #{minimum})"
      end
    rescue ArgumentError
      result :proxy_version, :warn, "running image tag #{version} is not a version number"
    end

    # Mirrors `proxy boot`: with reboot_on_deploy enabled it reboots a drifted
    # proxy on its own, and a MINIMUM_VERSION bump moves the expected config
    # digest, so a merely-stale proxy is converged by the very deploy this
    # doctor gates. Only a version the deploy would not touch — pinned in the
    # config, or with automatic reboots disabled — is a real failure. Any error
    # probing drift falls back to the conservative answer.
    def deploy_reboots_proxy?
      DASH.config.proxy.reboot_on_deploy? && Dash::Cli::Proxy::Drift.new(host, sshkit).drifted?
    rescue StandardError
      false
    end

    # What a container path has to look like to count as a container runtime
    # socket when the config no longer names one.
    DOCKER_SOCKET_PATTERN = %r{docker\.sock\z}

    # The config-time sleep/docker_socket pairing check covers the *current*
    # config; the running container keeps whatever it was booted with. A proxy
    # from before the socket was added silently lacks the mount - the failure
    # mode is one hung request when a sleeping service never wakes - and one
    # from before it was removed keeps root-equivalent host access.
    def proxy_socket_check(proxy_running:)
      expected = DASH.config.proxy_run(host)&.docker_socket

      unless proxy_running
        detail = expected ? "docker socket #{expected} will be mounted on boot" : "no docker socket configured"
        return result(:proxy_socket, :ok, detail)
      end

      mounted = capture_with_info(*DASH.proxy(host).mount_destinations, raise_on_non_zero_exit: false).split("\n").map(&:strip)

      if expected
        if mounted.include?(expected)
          result :proxy_socket, :ok, "docker socket #{expected} is mounted"
        elsif sleep_configured?
          result :proxy_socket, :fail, "the running dash-proxy has no #{expected} mount, so sleeping services never wake - run `dash proxy reboot`"
        else
          # Nothing sleeps yet, so nothing hangs - drift rather than breakage.
          result :proxy_socket, :warn, "the running dash-proxy has no #{expected} mount - run `dash proxy reboot` to apply the current configuration"
        end
      elsif (stray = mounted.grep(DOCKER_SOCKET_PATTERN).first)
        result :proxy_socket, :warn, "the running dash-proxy mounts #{stray} but the config no longer asks for it - " \
          "the socket is root-equivalent host access; `dash proxy reboot` removes it"
      else
        result :proxy_socket, :ok, "no docker socket configured or mounted"
      end
    rescue StandardError => e
      result :proxy_socket, :warn, "could not check the docker socket (#{e.message})"
    end

    def sleep_configured?
      DASH.config.roles.any? { |role| role.running_proxy? && role.proxy.proxy_config["sleep"].present? }
    end

    def ports_check(proxy_running:, legacy_proxy_running: false)
      run_config = DASH.config.proxy_run(host)
      return result(:ports, :ok, "proxy ports are not published, nothing to check") if run_config && !run_config.publish?

      http_port = run_config&.http_port || Dash::Configuration::Proxy::Run::DEFAULT_HTTP_PORT
      https_port = run_config&.https_port || Dash::Configuration::Proxy::Run::DEFAULT_HTTPS_PORT

      if proxy_running
        result :ports, :ok, "ports #{http_port}/#{https_port} held by the running dash-proxy"
      elsif legacy_proxy_running
        result :ports, :ok,
          "ports #{http_port}/#{https_port} held by the running #{Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME}, " \
          "replaced on the next deploy"
      elsif (busy = busy_ports(http_port, https_port)).any?
        result :ports, :fail, "port(s) #{busy.join(", ")} already in use by another process"
      else
        result :ports, :ok, "ports #{http_port}/#{https_port} free"
      end
    rescue StandardError => e
      result :ports, :warn, "could not check ports (#{e.message})"
    end

    def busy_ports(*ports)
      ports.select { |port| capture_with_info(*DASH.server.listeners_on(port), raise_on_non_zero_exit: false).present? }
    end

    def expected_proxy_image
      DASH.config.proxy_run(host)&.image || "#{DASH.config.proxy_boot.image_default}:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
    end

    def registry_name
      DASH.config.registry.server || "Docker Hub"
    end
end
