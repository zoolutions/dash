class Dash::Cli::Server < Dash::Cli::Base
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
end
