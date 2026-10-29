# One `scale.hold_when` entry: a saturation guard. While its query reads above `above` (or
# cannot be read), the controller holds a signal-driven scale-out - more containers would
# only queue on the database. A schedule floor still applies. See Dash::Autoscale::Guard.
class Dash::Configuration::Role::Scale::Guard
  SOURCES = %w[ prometheus postgres ]
  KEYS = %w[ source query above ]

  attr_reader :source, :query, :above

  def initialize(guard_config:, context:)
    @context = context
    error nil, "should be a hash" unless guard_config.is_a?(Hash)
    if (unknown = (guard_config.keys.map(&:to_s) - KEYS).first)
      error nil, "unknown key: #{unknown}"
    end

    @source = guard_config["source"].to_s
    @query = guard_config["query"]
    @above = guard_config["above"]

    error "source", "must be #{SOURCES.join(" or ")}, not #{source}" unless SOURCES.include?(source)
    error "query", "is required" unless query.is_a?(String) && query.present?
    error "above", "is required" if above.nil?
    error "above", "should be a finite number" unless above.is_a?(Numeric) && above.real? && above.finite?
  end

  # The autoscale/<connection> block the guard reads through.
  def connection
    source
  end

  def to_h
    { source: source, query: query, above: above }
  end

  private
    def error(key, message)
      raise Dash::ConfigurationError, "#{[ @context, key ].compact.join("/")}: #{message}"
    end
end
