require "json"

# Per app host, the resource use of every running container of this service: CPU, memory,
# network and block I/O and PIDs, with its role, replica slot and version - then each
# accessory's container on its own hosts. A point-in-time
# sample - `docker stats --no-stream` measures over about a second, per host, in parallel.
#
# Every number keeps its raw string under `raw:`; a value docker printed in a form Units
# cannot read becomes nil there, never a wrong number.
class Dash::Diagnostics::ContainerStats < Dash::Diagnostics::Base
  # `accessories: []` for the app alone, `hosts: []` for accessories alone.
  def initialize(hosts: DASH.app_hosts, accessories: DASH.config.accessories)
    @hosts = hosts
    @accessories = accessories
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| { containers: containers(backend.capture_with_info(*DASH.app.stats_json, raise_on_non_zero_exit: false)) } },
        accessories: per_accessory(@accessories) do |accessory, backend, _host|
          { containers: containers(backend.capture_with_info(*DASH.accessory(accessory.name).stats_json, raise_on_non_zero_exit: false), accessory: accessory.name) }
        end }
    end

    def containers(output, accessory: nil)
      ps, stats = output.to_s.split(/^#{Regexp.escape(Dash::Commands::Base::SECTION_SEPARATOR)}$/, 2)
      by_id = stats.to_s.lines.filter_map { |line| JSON.parse(line) if line.strip.present? }.index_by { |sample| sample["ID"].to_s[0, 12] }

      Dash::Diagnostics::DockerPs.containers(ps, accessory: accessory).map do |container|
        sample = by_id[container[:id].to_s[0, 12]]
        container.merge(stats: sample && stats_of(sample))
      end
    end

    def stats_of(sample)
      memory, memory_limit = Dash::Diagnostics::Units.pair(sample["MemUsage"])
      net_rx, net_tx = Dash::Diagnostics::Units.pair(sample["NetIO"])
      block_read, block_write = Dash::Diagnostics::Units.pair(sample["BlockIO"])

      { cpu_percent: Dash::Diagnostics::Units.percent(sample["CPUPerc"]),
        memory_bytes: memory, memory_limit_bytes: memory_limit, memory_percent: Dash::Diagnostics::Units.percent(sample["MemPerc"]),
        net_rx_bytes: net_rx, net_tx_bytes: net_tx, block_read_bytes: block_read, block_write_bytes: block_write,
        pids: Integer(sample["PIDs"].to_s, 10, exception: false),
        raw: { cpu: sample["CPUPerc"], memory: sample["MemUsage"], net_io: sample["NetIO"], block_io: sample["BlockIO"] } }
    end
end
