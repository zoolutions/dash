class Dash::Cli::Server < Dash::Cli::Base
  HOST_STATS_COLUMNS = "%-20s %-16s %4s %-20s %-16s %-12s %-12s %s".freeze

  desc "exec", "Run a custom command on the server (use --help to show options)"
  option :interactive, type: :boolean, aliases: "-i", default: false, desc: "Run the command interactively (use for console/bash)"
  option :raw, type: :boolean, default: false, desc: "Output raw, unmodified stdout"
  def exec(*cmd)
    raw = options[:raw]

    if raw && options[:interactive]
      raise ArgumentError, "Raw is not compatible with interactive"
    end

    with_raw_output(raw) do
      pre_connect_if_required

      cmd = Dash::Utils.join_commands(cmd)
      hosts = DASH.hosts
      quiet = options[:quiet]

      case
      when options[:interactive]
        host = DASH.primary_host

        say "Running '#{cmd}' on #{host} interactively...", :magenta

        run_locally { exec DASH.server.run_over_ssh(cmd, host: host) }
      else
        say "Running '#{cmd}' on #{hosts.join(', ')}...", :magenta

        on(hosts) do |host|
          execute *DASH.auditor.record("Executed cmd '#{cmd}' on #{host}"), verbosity: :debug
          puts_by_host host, capture_with_info(cmd, strip: !raw), quiet: quiet, raw: raw
        end
      end
    end
  end

  desc "stats", "Show load, memory, swap, disk and uptime of the servers"
  option :json, type: :boolean, default: false, desc: "Print the stats per host as JSON"
  def stats
    return puts_json { Dash::Diagnostics::HostStats.new.to_h } if options[:json]

    pre_connect_if_required
    puts format(HOST_STATS_COLUMNS, "HOST", "LOAD 1/5/15", "CPUS", "MEMORY USED", "SWAP USED", "DISK /", "DISK DOCKER", "UPTIME")
    Dash::Diagnostics::HostStats.new.to_h[:hosts].each { |host| puts host_stats_line(host) }
  end

  desc "bootstrap", "Set up Docker to run dash apps"
  def bootstrap
    modify(lock: true) do
      missing = []

      on(DASH.hosts) do |host|
        unless execute(*DASH.docker.installed?, raise_on_non_zero_exit: false)
          if execute(*DASH.docker.superuser?, raise_on_non_zero_exit: false)
            info "Missing Docker on #{host}. Installing…"
            execute *DASH.docker.install

            unless execute(*DASH.docker.root?, raise_on_non_zero_exit: false) ||
                   execute(*DASH.docker.in_docker_group?, raise_on_non_zero_exit: false)
              execute *DASH.docker.add_to_docker_group
              begin
                execute *DASH.docker.refresh_session
              rescue IOError
                info "Session refreshed due to group change."
              end
            end
          else
            missing << host
          end
        end
      end

      if missing.any?
        raise "Docker is not installed on #{missing.join(", ")} and can't be automatically installed without having root access and either `wget` or `curl`. Install Docker manually: https://docs.docker.com/engine/install/"
      end

      run_hook "docker-setup"
    end
  end

  private
    def host_stats_line(host)
      return format("%-20s ERROR %s", host[:host], host[:error]) if host[:error]

      load = host[:load] ? host[:load].values_at(:one, :five, :fifteen).join("/") : "-"
      memory = host[:memory] ? "#{host[:memory][:used_percent]}% of #{Dash::Utils.human_bytes(host[:memory][:total_bytes])}" : "-"
      format(HOST_STATS_COLUMNS, host[:host], load, host[:cpus] || "-", memory, swap_used(host[:swap]), disk_used(host[:disk][:root]), disk_used(host[:disk][:docker_root]), uptime(host[:uptime_seconds]))
    end

    # A host with no swap configured reads "none" rather than a 0% that suggests headroom.
    def swap_used(swap)
      return "-" unless swap
      return "none" if swap[:total_bytes].to_i.zero?

      used = ((swap[:total_bytes] - swap[:free_bytes]) * 100.0 / swap[:total_bytes]).round
      "#{used}% of #{Dash::Utils.human_bytes(swap[:total_bytes])}"
    end

    def disk_used(disk)
      disk ? "#{disk[:used_percent].round}%" : "-"
    end

    def uptime(seconds)
      return "-" unless seconds

      days, rest = seconds.divmod(86_400)
      days > 0 ? "#{days}d #{rest / 3600}h" : "#{rest / 3600}h #{rest % 3600 / 60}m"
    end
end
