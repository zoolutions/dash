# A `scale.hold_when` guard as the controller reads it. A Reading pairs the guard (its index,
# source and bound) with its Sample: it holds a signal-driven scale-out while its value is
# above the bound, or while it cannot be read.
class Dash::Autoscale::Guard
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
