# A role's `scale.signal` as the controller reads it: one number per tick, from Redis
# (Sidekiq), Postgres (pgbus) or Prometheus, through the process's
# Dash::Autoscale::Connections, or from the role's own dash-proxies over SSH (proxy). A
# reader never raises out of a tick: a failure becomes a Sample with its error, and the
# policy holds the role. Only a configuration error (a missing gem, a secret that resolves
# to nothing) goes through, for the operator to fix.
class Dash::Autoscale::Signal
  attr_reader :config, :connections, :role

  def self.for(role, connections)
    { "sidekiq" => Sidekiq, "pgbus" => Pgbus, "prometheus" => Prometheus, "proxy" => Proxy }
      .fetch(role.scale.signal.source).new(role.scale.signal, connections, role: role)
  end

  # `config` is the role's Dash::Configuration::Role::Scale::Signal.
  def initialize(config, connections, role: nil)
    @config, @connections, @role = config, connections, role
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
