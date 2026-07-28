# Remote readiness checks for a single host, run inside an SSHKit backend.
#
# Every check rescues StandardError at its boundary: the doctor's contract is
# to report broken environments, not crash on them, and a failed connection can
# raise anything from Net::SSH errors to Errno and DNS resolution errors.
class Kamal::Cli::Doctor::HostChecks
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
      Kamal::Cli::Doctor::Result.new(check, host, status, detail)
    end

    def ssh_check
      execute "true"
      result :ssh, :ok, "connected"
    rescue StandardError => e
      result :ssh, :fail, "#{e.class}: #{e.message}"
    end

    def docker_check
      if execute(*KAMAL.docker.running?, raise_on_non_zero_exit: false)
        result :docker, :ok, "docker is installed and running"
      else
        result :docker, :fail, "docker is not installed or not running (run `kamal server bootstrap`)"
      end
    rescue StandardError => e
      result :docker, :fail, "#{e.class}: #{e.message}"
    end

    def registry_check
      return result(:registry, :ok, "local registry, no login required") if KAMAL.registry.local?

      if execute(*KAMAL.registry.login, raise_on_non_zero_exit: false)
        result :registry, :ok, "logged in to #{registry_name}"
      else
        result :registry, :fail, "docker login to #{registry_name} failed (check registry credentials)"
      end
    rescue StandardError => e
      result :registry, :fail, "#{e.class}: #{e.message}"
    end

    def proxy_checks
      version, version_error = capture_proxy_version

      {
        proxy_image: proxy_image_check,
        proxy_version: proxy_version_check(version, version_error),
        ports: ports_check(proxy_running: version.present?)
      }
    end

    def capture_proxy_version
      [ capture_with_info(*KAMAL.proxy(host).version).strip.presence, nil ]
    rescue StandardError => e
      [ nil, e ]
    end

    def proxy_image_check
      image = expected_proxy_image

      if execute(*KAMAL.docker.manifest_available?(image), raise_on_non_zero_exit: false)
        result :proxy_image, :ok, "#{image} manifest is fetchable"
      else
        result :proxy_image, :fail, "cannot fetch the manifest for #{image} (registry unreachable or unauthorized)"
      end
    rescue StandardError => e
      result :proxy_image, :fail, "#{e.class}: #{e.message}"
    end

    def proxy_version_check(version, error)
      minimum = Kamal::Configuration::Proxy::Run::MINIMUM_VERSION

      if error
        result :proxy_version, :warn, "could not determine the running version (#{error.message})"
      elsif version.nil?
        result :proxy_version, :ok, "not running (will be started on deploy)"
      elsif Kamal::Utils.older_version?(version, minimum)
        result :proxy_version, :fail, "#{version} is older than the minimum #{minimum}, run `kamal proxy reboot` to update"
      else
        result :proxy_version, :ok, "#{version} (minimum #{minimum})"
      end
    rescue ArgumentError
      result :proxy_version, :warn, "running image tag #{version} is not a version number"
    end

    def ports_check(proxy_running:)
      run_config = KAMAL.config.proxy_run(host)
      return result(:ports, :ok, "proxy ports are not published, nothing to check") if run_config && !run_config.publish?

      http_port = run_config&.http_port || Kamal::Configuration::Proxy::Run::DEFAULT_HTTP_PORT
      https_port = run_config&.https_port || Kamal::Configuration::Proxy::Run::DEFAULT_HTTPS_PORT

      if proxy_running
        result :ports, :ok, "ports #{http_port}/#{https_port} held by the running kamal-proxy"
      elsif (busy = busy_ports(http_port, https_port)).any?
        result :ports, :fail, "port(s) #{busy.join(", ")} already in use by another process"
      else
        result :ports, :ok, "ports #{http_port}/#{https_port} free"
      end
    rescue StandardError => e
      result :ports, :warn, "could not check ports (#{e.message})"
    end

    def busy_ports(*ports)
      ports.select { |port| capture_with_info(*KAMAL.server.listeners_on(port), raise_on_non_zero_exit: false).present? }
    end

    def expected_proxy_image
      KAMAL.config.proxy_run(host)&.image || "#{KAMAL.config.proxy_boot.image_default}:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}"
    end

    def registry_name
      KAMAL.config.registry.server || "Docker Hub"
    end
end
