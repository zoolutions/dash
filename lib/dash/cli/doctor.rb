require "dash/sshkit_with_ext"

# Runs read-only deploy readiness checks and collects the results, without ever
# raising on a broken environment - failures become failing results instead.
class Dash::Cli::Doctor
  include SSHKit::DSL

  HOST_CHECKS = %i[ ssh docker registry proxy_image proxy_version proxy_socket ports ]

  CHECK_TITLES = {
    ssh: "SSH",
    docker: "Docker",
    registry: "Registry",
    proxy_image: "Proxy image",
    proxy_version: "Proxy version",
    proxy_socket: "Proxy docker socket",
    ports: "Ports",
    dns: "DNS",
    certificate: "Certificates",
    readiness: "Readiness",
    dockerfile: "Dockerfile",
    drift: "Drift"
  }.freeze

  STATUS_COLORS = { ok: :green, warn: :yellow, fail: :red }.freeze

  Result = Struct.new(:check, :target, :status, :detail) do
    def ok?
      status == :ok
    end

    def warn?
      status == :warn
    end

    def fail?
      status == :fail
    end

    def title
      CHECK_TITLES[check]
    end

    def to_s
      "#{status.to_s.upcase} #{target}: #{detail}"
    end
  end

  attr_reader :results

  # `registry: false` leaves out the registry check, the one check that is not read-only:
  # it runs `docker login` on every host. `dash mcp` asks for that.
  def initialize(registry: true)
    @results = []
    @registry = registry
  end

  def run
    @results = host_check_results + endpoint_check_results + config_check_results + drift_check_results
  end

  def failures
    results.select(&:fail?)
  end

  def warnings
    results.select(&:warn?)
  end

  def successful?
    failures.none?
  end

  private
    def host_check_results
      results_by_host = collect_host_checks

      HOST_CHECKS.flat_map do |check|
        DASH.hosts.filter_map { |host| results_by_host.dig(host, check) }
      end
    end

    def collect_host_checks
      results_by_host = {}
      mutex = Mutex.new
      proxy_hosts = DASH.proxy_hosts
      registry = @registry
      error = nil

      begin
        on(DASH.hosts) do |host|
          checks = Dash::Cli::Doctor::HostChecks.new(host.hostname, self, proxy_host: proxy_hosts.include?(host.hostname), registry: registry).run
          mutex.synchronize { results_by_host[host.hostname] = checks }
        end
      # Only ExecuteError: sshkit 1.25 has no MultipleExecuteError, and naming
      # a constant that does not exist turns "a host's checks failed" into a
      # NameError - the opposite of the doctor's never-crash contract.
      rescue SSHKit::Runner::ExecuteError => e
        # Per-check errors are captured inside HostChecks; getting here means a
        # host's checks never completed at all. Record those as SSH failures below.
        error = e
      end

      DASH.hosts.each do |host|
        results_by_host[host] ||= { ssh: Result.new(:ssh, host, :fail, "could not run checks (#{error&.message || "connection failed"})") }
      end

      results_by_host
    end

    def endpoint_check_results
      Dash::Cli::Doctor::EndpointChecks.new.run
    end

    def config_check_results
      Dash::Cli::Doctor::ConfigChecks.new.run
    end

    # Whether the proxies route to what runs. A target that is not running, or a host the
    # load balancer should forward to and does not, fails; the rest warn.
    def drift_check_results
      drift = Dash::Diagnostics::Drift.take
      unread = drift.unread.map { |host| Result.new(:drift, host[:host], :warn, "could not read #{host[:source]} (#{host[:error]}), so it was not compared") }

      if drift.entries.empty? && unread.empty?
        [ Result.new(:drift, "proxy", :ok, "proxy targets match the running containers") ]
      else
        unread + drift.entries.map do |entry|
          status = Dash::Diagnostics::Drift::FAILURES.include?(entry[:code]) ? :fail : :warn
          Result.new(:drift, entry[:host] || entry[:role], status, "#{entry[:code]}: #{entry[:detail]}")
        end
      end
    rescue StandardError => e
      [ Result.new(:drift, "proxy", :warn, "could not compare proxy targets with containers (#{e.class}: #{e.message})") ]
    end
end
