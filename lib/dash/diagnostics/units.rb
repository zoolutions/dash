# Reads the units `docker stats` prints. Memory comes in binary units ("120MiB / 1.9GiB"),
# network and block I/O in decimal ones ("1.2kB / 0B"), CPU as "1.23%". Anything else
# reads as nil, so a caller keeps the raw string rather than a wrong number.
module Dash::Diagnostics::Units
  MULTIPLIERS = {
    "B" => 1,
    "kB" => 1000, "KB" => 1000, "MB" => 1000**2, "GB" => 1000**3, "TB" => 1000**4,
    "KiB" => 1024, "MiB" => 1024**2, "GiB" => 1024**3, "TiB" => 1024**4
  }.freeze

  QUANTITY = /\A(\d+(?:\.\d+)?)\s*([kKMGT]i?B|B)\z/

  module_function

  def bytes(value)
    if (match = QUANTITY.match(value.to_s.strip))
      (match[1].to_f * MULTIPLIERS.fetch(match[2])).round
    end
  end

  # "used / limit" or "in / out", as two byte counts.
  def pair(value)
    first, second = value.to_s.split("/", 2)
    [ bytes(first), bytes(second) ]
  end

  def percent(value)
    Float(value.to_s.strip.delete_suffix("%"), exception: false)
  end
end
