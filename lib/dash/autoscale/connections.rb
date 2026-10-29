require "net/ssh"
require "timeout"

# The controller's clients for its signals and guards - Redis, Postgres, Prometheus - one per
# source for the whole process, so they outlive `reconfigure!` and every tick reuses them.
# Each is built on first use, through a Dash::Autoscale::Tunnel when the source has `via`,
# and rebuilt after an error, when its URL, via or Prometheus token changes, or when its tunnel died.
#
# One read at a time per source: neither redis-client nor pg connections are thread-safe,
# and the drain's busy polls (inside SSHKit's `on` threads) share them with the tick.
class Dash::Autoscale::Connections
  DEFAULT_PORTS = { redis: 6379, postgres: 5432 }.freeze

  # Errors that leave a client (or the tunnel under it) unusable. Anything else - a query
  # that failed, a malformed job, an HTTP error status - keeps it: the next tick reuses it.
  # The drivers' classes are named, since their gems may not be loaded.
  CONNECTION_ERRORS = [ IOError, SystemCallError, SocketError, Timeout::Error, Net::SSH::Exception ].freeze
  DRIVER_CONNECTION_ERRORS = %w[ RedisClient::ConnectionError RedisClient::ProtocolError PG::ConnectionBad PG::UnableToSend ].freeze

  Entry = Struct.new(:key, :client, :tunnel)

  # The process's connections: the controller's, and the drain's when `dash scale set` runs
  # inside it. Closed by the controller when it stops; a later read opens them again.
  def self.shared
    @shared ||= new
  end

  def initialize(config: -> { DASH.config }, builder: Builder.method(:build), tunnel: Dash::Autoscale::Tunnel.method(:open))
    @config, @builder, @tunnel = config, builder, tunnel
    @entries = {}
    @locks = Hash.new { |locks, source| locks[source] = Mutex.new }
    @locks_lock = Mutex.new
  end

  def with(source)
    source = source.to_sym

    lock(source).synchronize do
      entry = entry_for(source)

      begin
        yield entry.client
      rescue StandardError => e
        discard(source) if connection_error?(e)
        raise
      end
    end
  end

  def close
    @entries.keys.each { |source| lock(source).synchronize { discard(source) } }
  end

  private
    def lock(source)
      @locks_lock.synchronize { @locks[source] }
    end

    # A client is kept while what it was built from - the URL, via and, for Prometheus, the
    # token it sends - stays the same.
    def entry_for(source)
      autoscale = @config.call.autoscale
      url, via = autoscale.source_url(source), autoscale.source_via(source)
      key = [ url, via, (autoscale.prometheus_token if source == :prometheus) ]
      entry = @entries[source]
      return entry if entry && entry.key == key && (entry.tunnel.nil? || entry.tunnel.alive?)

      discard(source)
      @entries[source] = build(source, url, via, key)
    end

    def build(source, url, via, key)
      uri = URI(url)
      raise Dash::ConfigurationError, "autoscale/#{source}: via needs a URL that names its host" if via && uri.host.blank?

      tunnel = @tunnel.call(via, uri.host, uri.port || DEFAULT_PORTS.fetch(source)) if via
      Entry.new(key, @builder.call(source, url, tunnel, config: @config.call), tunnel)
    rescue StandardError
      tunnel&.close
      raise
    end

    def connection_error?(error)
      CONNECTION_ERRORS.any? { |type| error.is_a?(type) } || error.class.ancestors.any? { |type| DRIVER_CONNECTION_ERRORS.include?(type.name) }
    end

    def discard(source)
      entry = @entries.delete(source)
      return unless entry

      close_quietly(entry.client)
      close_quietly(entry.tunnel)
    end

    # A client or tunnel being thrown away after an error may fail to close; the error
    # that matters has been raised already.
    def close_quietly(closable)
      closable&.close
    rescue StandardError
      nil
    end
end
