# The `scale.signal` entry: the one number the controller scales a role on. `sidekiq` and
# `pgbus` are the age in seconds of the oldest job waiting across `queues`; `prometheus` is
# whatever its `query` returns (the largest value of a vector); `proxy` is the fleet p95 of
# web request queue time in milliseconds, read from each host's dash-proxy. See
# Dash::Autoscale::Signal.
class Dash::Configuration::Role::Scale::Signal
  SOURCES = %w[ sidekiq pgbus prometheus proxy ]
  KEYS = %w[ source queues prefix query ]
  NAME = /\A[A-Za-z0-9_.:-]+\z/
  DEFAULT_PGBUS_PREFIX = "pgbus_"

  # The autoscale/<connection> block each source reads through. `proxy` has none: it reads
  # each host's dash-proxy over SSH, as `dash doctor` does.
  CONNECTIONS = { "sidekiq" => "redis", "pgbus" => "postgres", "prometheus" => "prometheus" }.freeze

  attr_reader :source, :queues, :prefix, :query

  def initialize(signal_config:, context:)
    @context = context
    error nil, "should be a hash" unless signal_config.is_a?(Hash)
    if (unknown = (signal_config.keys.map(&:to_s) - KEYS).first)
      error nil, "unknown key: #{unknown}"
    end

    @source = signal_config["source"].to_s
    validate_source!
    @queues = parse_queues(signal_config["queues"])
    @prefix = parse_prefix(signal_config["prefix"])
    @query = parse_query(signal_config["query"])
  end

  def queues?
    %w[ sidekiq pgbus ].include?(source)
  end

  def connection
    CONNECTIONS[source]
  end

  def to_h
    { source: source, queues: queues, prefix: prefix, query: query }.compact
  end

  private
    def validate_source!
      error "source", "must be #{SOURCES.to_sentence(last_word_connector: " or ")}, not #{source}" unless SOURCES.include?(source)
    end

    def parse_queues(queues)
      unless queues?
        error "queues", "is only used with sidekiq and pgbus" unless queues.nil?
        return
      end

      error "queues", "is required for #{source}" if queues.nil? || queues == []
      error "queues", "should be an array" unless queues.is_a?(Array)
      queues.each_with_index { |queue, index| error "queues/#{index}", "#{queue.inspect} #{name_rule}" unless name?(queue) }
      queues
    end

    def parse_prefix(prefix)
      unless source == "pgbus"
        error "prefix", "is only used with pgbus" unless prefix.nil?
        return
      end

      return DEFAULT_PGBUS_PREFIX if prefix.nil?
      error "prefix", "#{prefix.inspect} #{name_rule}" unless name?(prefix)
      prefix
    end

    def parse_query(query)
      unless source == "prometheus"
        error "query", "is only used with prometheus" unless query.nil?
        return
      end

      error "query", "is required for prometheus" unless query.is_a?(String) && query.present?
      query
    end

    def name?(value)
      value.is_a?(String) && NAME.match?(value)
    end

    def name_rule
      "should be letters, digits, _ . : or -"
    end

    def error(key, message)
      raise Dash::ConfigurationError, "#{[ @context, key ].compact.join("/")}: #{message}"
    end
end
