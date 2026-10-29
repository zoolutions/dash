# The controller's clients for its signals and guards - Redis, Postgres, Prometheus - one per
# source for the whole process, so they outlive `reconfigure!` and every tick reuses them.
# Each is built on first use, through a Dash::Autoscale::Tunnel when the source has `via`,
# and rebuilt after an error, when its URL or via changes, or when its tunnel died.
#
# One read at a time per source: neither redis-client nor pg connections are thread-safe,
# and the drain's busy polls (inside SSHKit's `on` threads) share them with the tick.
class Dash::Autoscale::Connections
  DEFAULT_PORTS = { redis: 6379, postgres: 5432 }.freeze

  Entry = Struct.new(:key, :client, :tunnel)

  # The process's connections: the controller's, and the drain's when `dash scale set` runs
  # inside it. Closed by the controller when it stops.
  def self.shared
    @shared ||= new
  end

  def self.close_shared
    @shared&.close
    @shared = nil
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
      rescue StandardError
        discard(source)
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

    def entry_for(source)
      autoscale = @config.call.autoscale
      url, via = autoscale.source_url(source), autoscale.source_via(source)
      entry = @entries[source]
      return entry if entry && entry.key == [ url, via ] && (entry.tunnel.nil? || entry.tunnel.alive?)

      discard(source)
      @entries[source] = build(source, url, via)
    end

    def build(source, url, via)
      uri = URI(url)
      tunnel = @tunnel.call(via, uri.host, uri.port || DEFAULT_PORTS.fetch(source)) if via
      Entry.new([ url, via ], @builder.call(source, url, tunnel, config: @config.call), tunnel)
    rescue StandardError
      tunnel&.close
      raise
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
