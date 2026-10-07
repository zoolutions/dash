# A length of time as deploy.yml and the CLI write it: integer seconds, or a whole number
# with a unit - `90s`, `15m`, `30h`, `7d`. Returns seconds.
module Dash::Autoscale::Duration
  UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
  FORMAT = /\A(\d+)([smhd]?)\z/

  def self.parse(value)
    case value
    when Integer
      return value unless value.negative?
    when String
      if (match = FORMAT.match(value))
        return Integer(match[1], 10) * UNITS.fetch(match[2].presence || "s")
      end
    end

    raise ArgumentError, "#{value.inspect} should be seconds, or a number followed by s, m, h or d (30m, 2h, 1d)"
  end
end
