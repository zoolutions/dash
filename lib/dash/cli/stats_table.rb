# The human table for `dash app stats` and `dash accessory stats`: one block per host, a
# row per container. The JSON is the ContainerStats diagnostic's own `to_h`.
module Dash::Cli::StatsTable
  COLUMNS = "  %-28s %-10s %4s %8s %21s %6s".freeze

  module_function

  # `host` is one entry of ContainerStats#to_h's `hosts` or `accessories`.
  def lines(type, host)
    heading = "#{type} Host: #{host[:host]}"
    return [ heading, "  ERROR #{host[:error]}" ] if host[:error]
    return [ heading, "  no containers running" ] if host[:containers].empty?

    [ heading, format(COLUMNS, "CONTAINER", host[:accessory] ? "ACCESSORY" : "ROLE", "SLOT", "CPU", "MEMORY / LIMIT", "PIDS"),
      *host[:containers].map { |container| row(container) } ]
  end

  def row(container)
    stats = container[:stats] || {}

    format COLUMNS, container[:name], container[:role] || container[:accessory], container[:replica] || "-",
      percent(stats[:cpu_percent]), memory(stats), stats[:pids] || "-"
  end

  def percent(value)
    value ? format("%.1f%%", value) : "-"
  end

  def memory(stats)
    return stats.dig(:raw, :memory) || "-" unless stats[:memory_bytes] && stats[:memory_limit_bytes]

    "#{Dash::Utils.human_bytes(stats[:memory_bytes])} / #{Dash::Utils.human_bytes(stats[:memory_limit_bytes])}"
  end
end
