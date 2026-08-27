class Dash::Cli::Lock < Dash::Cli::Base
  desc "status", "Report lock status"
  option :server, type: :boolean, default: false, desc: "Report the shared server lock instead of the deploy lock"
  def status
    if options[:server]
      report_server_lock_status
    else
      handle_missing_lock do
        puts capture_lock_status
      end
    end
  end

  desc "acquire", "Acquire the deploy lock"
  option :message, aliases: "-m", type: :string, desc: "A lock message", required: true
  def acquire
    ensure_run_directory

    raise_if_locked do
      execute_lock_acquire(options[:message])
      say "Acquired the deploy lock"
    end
  end

  desc "release", "Release the deploy lock"
  option :server, type: :boolean, default: false, desc: "Release the shared server lock instead of the deploy lock"
  def release
    if options[:server]
      release_server_lock_on(server_lock_hosts)
      say "Released the server lock"
    else
      handle_missing_lock do
        execute_lock_release
        say "Released the deploy lock"
      end
    end
  end

  private
    def handle_missing_lock
      yield
    rescue LockMissingError
      say "There is no deploy lock"
    end

    # The server lock is taken per host rather than per destination, so report
    # each one: an acquire that failed part-way leaves it held on a subset.
    def report_server_lock_status
      server_lock_hosts.each do |host|
        if (status = server_lock_status_on(host))
          say "Server lock on #{host}:"
          puts status
        else
          say "There is no server lock on #{host}"
        end
      end
    end

    def server_lock_status_on(host)
      capture_lock_status(lock: DASH.server_lock, hosts: host)
    rescue LockMissingError
      nil
    end
end
