class Dash::Cli::App::Boot
  # What `docker container ls --quiet` prints, and so what dash-proxy has always been
  # handed as a target. `docker run --detach` prints the full 64-character id, so the
  # target is its first twelve characters rather than a round trip of its own.
  SHORT_CONTAINER_ID_LENGTH = 12

  attr_reader :host, :role, :version, :barrier, :sshkit, :cli
  delegate :execute, :capture_with_info, :capture_with_pretty_json, :info, :error, :upload!, to: :sshkit
  delegate :run_hook, to: :cli
  delegate :assets?, :running_proxy?, to: :role

  def initialize(host, role, sshkit, version, barrier, cli)
    @host = host
    @role = role
    @version = version
    @barrier = barrier
    @sshkit = sshkit
    @cli = cli
  end

  # Every replica of the role on this host is swapped together: the old containers keep
  # serving until all the new ones are ready, and a failure stops every new one.
  def run
    DASH.timings.phase("#{role} #{host}", depth: 1) do |timing|
      @timing = timing

      @state = capture_boot_state
      announce_replicas if role.replicas.scalable?
      old_versions = old_versions_renamed_if_clashing

      wait_at_barrier if queuer?

      begin
        start_new_versions
      rescue => e
        close_barrier if gatekeeper?
        stop_new_versions
        raise
      end

      release_barrier if gatekeeper?

      stop_old_versions(old_versions)
    end
  end

  private
    attr_reader :state

    # Every answer comes back from one round trip, which means the running versions are
    # read before any rename happens. When a clashing container IS the running one, the
    # version to stop later is the name it was renamed to - the name that was read now
    # belongs to the container this boot is about to start.
    def old_versions_renamed_if_clashing
      old_versions = state.replicas.to_h { |replica| [ replica, state.running_version(replica) ] }

      state.replicas.select { |replica| state.clashing?(replica) }.each do |replica|
        renamed_version = "#{version}_replaced_#{SecureRandom.hex(8)}"
        info "Renaming container #{app(replica).container_name(version)} to #{renamed_version} as already deployed on #{host}"
        execute *auditor.record_then("Renaming container #{version} to #{renamed_version}",
          app(replica).rename_container(version: version, new_version: renamed_version))

        old_versions[replica] = renamed_version if old_versions[replica] == version
      end

      old_versions.merge(state.surplus_replicas.to_h { |replica| [ replica, state.running_version(replica) ] }).compact
    end

    # A slot that crashed between min and the runtime count is not running, so it is not
    # counted - say so, rather than letting the count drop silently.
    def announce_replicas
      info "Booting #{state.count} #{"replica".pluralize(state.count)} of #{role} on #{host} (#{state.running_count} of #{role.replicas.max} slots running, min #{role.replicas.min})"
    end

    def capture_boot_state
      Dash::Cli::App::BootState.new(role, capture_with_info(*app.boot_states(version), raise_on_non_zero_exit: false))
    end

    def start_new_versions
      execute *auditor.record_then("Booted app version #{version}", app.ensure_env_directory)
      upload! role.secrets_io(host), role.secrets_path, mode: "0600"

      container_ids = state.replicas.map { |replica| run_replica(replica) }

      if running_proxy?
        endpoints = container_ids.map { |container_id| container_id[0, SHORT_CONTAINER_ID_LENGTH] }
        raise Dash::Cli::BootError, "Failed to get endpoint for #{role} on #{host}, did the container boot?" if endpoints.any?(&:empty?)

        run_hook "pre-proxy-deploy", hosts: host.to_s, role: role.name
        info "Deploying #{role} on #{host} via dash-proxy (waiting up to #{DASH.config.deploy_timeout}s for it to become healthy)..."
        timing_healthy { execute *app.deploy(targets: endpoints) }
        run_hook "post-proxy-deploy", hosts: host.to_s, role: role.name
      else
        timing_healthy do
          state.replicas.each do |replica|
            Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: role) { |*args| readiness_status(replica, *args) }
          end
        end
      end
    rescue => e
      error "Failed to boot #{role} on #{host}"
      dump_diagnostics
      raise e
    end

    # `docker run --detach` prints the id of the container it just started, so the proxy
    # target comes out of the run itself — asking docker for it again was a round trip
    # spent re-reading something the host had already said.
    def run_replica(replica)
      hostname = "#{host.to_s[0...51].chomp(".")}-#{SecureRandom.hex(6)}"
      capture_with_info(*app(replica).run(hostname: hostname)).strip
    end

    # A role behind the proxy lets `dash-proxy deploy` block on the host until the
    # container is healthy; a role without one now does the same, waiting in a shell loop
    # on the host that streams its progress back rather than being polled from here once
    # per attempt. The poller asks for the wait, and — only for an unchecked container it
    # has just let through its readiness delay — for a plain confirming read.
    #
    # Neither capture suppresses a non-zero exit: a status that cannot be read is a broken
    # command, and it has always failed the boot on the spot rather than being waited out.
    def readiness_status(replica, mode, seconds_left = nil)
      if mode == :confirm
        capture_with_info(*app(replica).status(version: version))
      else
        capture_with_info *app(replica).wait_for_ready(version: version, timeout: seconds_left),
          interaction_handler: Dash::Cli::Healthcheck::ProgressReporter.new
      end
    end

    # Every failed boot gets the container log, and the health probe history when the
    # container declares a healthcheck — non-primary roles have no dash-proxy report to fall back on.
    def dump_diagnostics
      state.replicas.each do |replica|
        error capture_with_info(*app(replica).logs(container_id: app(replica).container_id_for_version(version)))

        health_log = capture_with_info(*app(replica).container_health_log(version: version)).strip
        error health_log unless health_log.empty? || health_log == "null"
      end
    rescue SSHKit::Command::Failed
      error "Could not fetch logs for #{version}"
    end

    def stop_new_versions
      state.replicas.each do |replica|
        execute *app(replica).stop(version: version), raise_on_non_zero_exit: false
      end
    end

    def stop_old_versions(old_versions)
      return if old_versions.empty?

      old_versions.each do |replica, old_version|
        run_stop_hook "pre-app-stop", old_version
        execute *app(replica).stop(version: old_version), raise_on_non_zero_exit: false
        run_stop_hook "post-app-stop", old_version
      end

      execute *app.clean_up_assets if assets?
      execute *app.clean_up_error_pages if DASH.config.error_pages_path
    end

    # The new version is already live by the time the old one is stopped, so a failing
    # drain hook must not fail the deploy — warn and stop the old container anyway.
    def run_stop_hook(hook, old_version)
      run_hook hook, hosts: host.to_s, role: role.name, version: old_version
    rescue Dash::Cli::HookError => e
      error "#{e.message}\nContinuing anyway: #{version} is already live for #{role} on #{host}."
    end

    def release_barrier
      if barrier.open
        info "First #{DASH.primary_role} container is healthy on #{host}, booting any other roles"
      end
    end

    def wait_at_barrier
      info "Waiting for the first healthy #{DASH.primary_role} container before booting #{role} on #{host}..."
      barrier.wait
      info "First #{DASH.primary_role} container is healthy, booting #{role} on #{host}..."
    rescue Dash::Cli::Healthcheck::Error
      info "First #{DASH.primary_role} container is unhealthy, not booting #{role} on #{host}"
      raise
    end

    def close_barrier
      if barrier.close
        info "First #{DASH.primary_role} container is unhealthy on #{host}, not booting any other roles"
      end
    end

    # The readiness wait is the part of a host's boot an operator can actually tune
    # (health check interval, app boot time), so it gets called out on the host's entry.
    def timing_healthy
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      replicas = ", #{state.count} replicas" if role.replicas.scalable?
      @timing.detail = format("healthy after %.1fs%s", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, replicas)
    end

    def barrier_role?
      role == DASH.primary_role
    end

    def app(replica = 1)
      @apps ||= {}
      @apps[replica] ||= DASH.app(role: role, host: host, replica: replica)
    end

    def auditor
      @auditor = DASH.auditor(role: role)
    end

    def gatekeeper?
      barrier && barrier_role?
    end

    def queuer?
      barrier && !barrier_role?
    end
end
