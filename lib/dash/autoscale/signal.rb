# A role's `scale.signal` as the controller reads it: one number per tick, from Redis
# (Sidekiq), Postgres (pgbus) or Prometheus, through the process's
# Dash::Autoscale::Connections. A reader never raises out of a tick: a failure becomes a
# Sample with its error, and the policy holds the role. Only a configuration error (a
# missing gem, a secret that resolves to nothing) goes through, for the operator to fix.
class Dash::Autoscale::Signal
  attr_reader :config, :connections

  def self.for(role, connections)
    { "sidekiq" => Sidekiq, "pgbus" => Pgbus, "prometheus" => Prometheus }.fetch(role.scale.signal.source).new(role.scale.signal, connections)
  end

  # `config` is the role's Dash::Configuration::Role::Scale::Signal.
  def initialize(config, connections)
    @config, @connections = config, connections
  end

  def sample(at: Time.now.utc)
    Dash::Autoscale::Sample.new(value: read(at), at: at)
  rescue Dash::ConfigurationError
    raise
  rescue StandardError => e
    Dash::Autoscale::Sample.new(value: nil, at: at, error: "#{e.class}: #{e.message}")
  end

  # Whether the source can say how many jobs a container is working on (only Sidekiq can):
  # a drain then ends as soon as it says none.
  def busy?
    false
  end
end
