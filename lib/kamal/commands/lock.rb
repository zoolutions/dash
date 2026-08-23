require "active_support/duration"
require "time"
require "base64"

class Kamal::Commands::Lock < Kamal::Commands::Base
  # The deploy lock is scoped to service+destination, so two destinations can
  # deploy at once. Server-scoped resources — above all the single kamal-proxy
  # container a host runs for every destination on it — need a lock that every
  # destination contends for, hence :server.
  SCOPES = %i[ destination server ].freeze

  attr_reader :scope

  def initialize(config, scope: :destination)
    raise ArgumentError, "Unknown lock scope: #{scope}" unless SCOPES.include?(scope)

    super(config)
    @scope = scope
  end

  def acquire(message, version)
    combine \
      [ :mkdir, lock_dir ],
      write_lock_details(message, version)
  end

  def release
    combine \
      [ :rm, lock_details_file ],
      [ :rm, "-r", lock_dir ]
  end

  def status
    combine \
      stat_lock_dir,
      read_lock_details
  end

  def ensure_locks_directory
    [ :mkdir, "-p", locks_dir ]
  end

  private
    def write_lock_details(message, version)
      write \
        [ :echo, "\"#{Base64.encode64(lock_details(message, version))}\"" ],
        lock_details_file
    end

    def read_lock_details
      pipe \
        [ :cat, lock_details_file ],
        [ :base64, "-d" ]
    end

    def stat_lock_dir
      write \
        [ :stat, lock_dir ],
        "/dev/null"
    end

    def lock_dir
      File.join(config.run_directory, lock_dir_name)
    end

    # A server-scoped lock deliberately carries neither service nor destination:
    # every deploy reaching this host must collide on the same directory.
    def lock_dir_name
      case scope
      when :server      then "lock-server"
      when :destination then [ "lock", config.service, config.destination ].compact.join("-")
      end
    end

    def lock_details_file
      File.join(lock_dir, "details")
    end

    def lock_details(message, version)
      <<~DETAILS.strip
        Locked by: #{locked_by} at #{Time.now.utc.iso8601}
        Version: #{version}
        Message: #{message}
      DETAILS
    end

    def locked_by
      Kamal::Git.user_name
    rescue Errno::ENOENT
      "Unknown"
    end
end
