# `dash doctor`: deploy readiness checks, collected as results without ever raising on a
# broken environment - failures become failing results instead. `to_h` is the same as data.
#
# Every check reads, except the registry check: it runs `docker login` on every host,
# which writes the registry credentials there. `registry: false` leaves it out, and
# `dash mcp` asks for that.
class Dash::Diagnostics::Doctor < Dash::Diagnostics::Base
  REGISTRY_SKIPPED = { check: "registry", reason: "runs docker login on each host, which writes credentials there; run `dash doctor` to include it" }.freeze

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
    drift: "Drift",
    pool: "Pool",
    controller: "Controller"
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

  # The roles this run is about. DASH.roles builds the host scope, which asks the autoscale
  # pool - so it is only used when --hosts narrowed the run, and the pool has been read
  # already to filter by them. Otherwise --roles, or every role, straight from deploy.yml.
  def self.scoped_roles
    DASH.specific_hosts ? DASH.roles : (DASH.specific_roles || DASH.config.roles)
  end

  def initialize(registry: true)
    @results = []
    @registry = registry
  end

  # Pool checks first: when the provider cannot be asked, the member hosts are unknown, so
  # the checks that need every host report that once instead of crashing on it.
  def run
    pool = pool_check_results
    @results = without_pool(:ssh) { host_check_results } + without_pool(:dns) { endpoint_check_results } +
      config_check_results + pool + controller_check_results + drift_check_results
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
    def snapshot
      run

      { successful: successful?, results: results.map { |result| result_h(result) }, skipped: (@registry ? [] : [ REGISTRY_SKIPPED ]) }
    end

    def result_h(result)
      { check: result.check.to_s, target: result.target.to_s, status: result.status.to_s, detail: result.detail.to_s }
    end

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
          checks = Dash::Diagnostics::Doctor::HostChecks.new(host.hostname, self, proxy_host: proxy_hosts.include?(host.hostname), registry: registry).run
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
      Dash::Diagnostics::Doctor::EndpointChecks.new.run
    end

    def config_check_results
      Dash::Diagnostics::Doctor::ConfigChecks.new.run
    end

    def pool_check_results
      Dash::Diagnostics::Doctor::PoolChecks.new.run
    end

    def controller_check_results
      Dash::Diagnostics::Doctor::ControllerChecks.new.run
    rescue StandardError => e
      [ Result.new(:controller, "controller", :warn, "could not check the autoscale controller (#{e.class}: #{e.message})") ]
    end

    def without_pool(check)
      yield
    rescue Dash::Autoscale::ProviderError => e
      [ Result.new(check, "pool", :fail, "not run, the pool members are unknown (#{e.message})") ]
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
