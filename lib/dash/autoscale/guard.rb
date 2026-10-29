# A `scale.hold_when` guard as the controller reads it. A Reading pairs the guard (its index,
# source and bound) with its Sample: it holds a signal-driven scale-out while its value is
# above the bound, or while it cannot be read.
class Dash::Autoscale::Guard
  # One Reading per guard, in order. A guard that cannot be read is a Reading with an error,
  # which holds; only a configuration error goes through.
  def self.read(guards, connections, at: Time.now.utc)
    guards.each_with_index.map do |guard, index|
      Reading.new(index: index, source: guard.source, above: guard.above, sample: sample(guard, connections, at))
    end
  end

  def self.sample(guard, connections, at)
    value = connections.with(guard.connection) do |client|
      if guard.source == "postgres"
        Dash::Autoscale::ReadOnlyQuery.within(client) { Dash::Autoscale::ReadOnlyQuery.number(client, guard.query) }
      else
        client.query(guard.query)
      end
    end

    Dash::Autoscale::Sample.new(value: value, at: at)
  rescue Dash::ConfigurationError
    raise
  rescue StandardError => e
    Dash::Autoscale::Sample.new(value: nil, at: at, error: "#{e.class}: #{e.message}")
  end
  private_class_method :sample

  Reading = Struct.new(:index, :source, :above, :sample, keyword_init: true) do
    def holding?
      sample.missing? || sample.value > above
    end

    def name
      "hold_when/#{index} #{source}"
    end

    # `hold_when/0 postgres 195 > 180`, or `hold_when/0 postgres: <error>`.
    def describe
      sample.missing? ? "#{name}: #{sample.error || "no value"}" : "#{name} #{sample.value} > #{above}"
    end

    def to_h
      { index: index, source: source, above: above }.merge(sample.to_h)
    end
  end
end
