# Per host, what the machine has left: load against its CPU count, memory and swap, disk
# for / and for Docker's data root, and uptime - one round trip of /proc reads and `df`.
#
# Each section is read on its own. A host whose Docker is down still reports its load,
# memory and root disk, with `docker_root: nil`; a section that does not parse is nil.
class Dash::Diagnostics::HostStats < Dash::Diagnostics::Base
  KIB = 1024

  def initialize(hosts: DASH.hosts)
    @hosts = hosts
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| stats(backend.capture_with_info(*DASH.server.stats, raise_on_non_zero_exit: false)) } }
    end

    def stats(output)
      loadavg, cpus, meminfo, df_root, df_docker, uptime = output.to_s.split(/^#{Regexp.escape(Dash::Commands::Base::SECTION_SEPARATOR)}$/).map(&:strip)
      cpus = Integer(cpus.to_s, 10, exception: false)
      meminfo = meminfo(meminfo)

      { load: load(loadavg, cpus), cpus: cpus, memory: memory(meminfo), swap: swap(meminfo),
        disk: { root: disk(df_root), docker_root: disk(df_docker) }, uptime_seconds: Float(uptime.to_s.split.first.to_s, exception: false)&.to_i }
    end

    # "0.52 0.48 0.40 2/345 6789"
    def load(loadavg, cpus)
      one, five, fifteen = loadavg.to_s.split.first(3).map { |value| Float(value, exception: false) }
      return unless one && five && fifteen

      { one: one, five: five, fifteen: fifteen, per_cpu: (cpus.to_i > 0 ? (one / cpus).round(2) : nil) }
    end

    # /proc/meminfo reports kB that are KiB.
    def meminfo(section)
      section.to_s.lines.to_h { |line| key, value = line.split(":", 2); [ key, value.to_s[/\d+/]&.to_i&.*(KIB) ] }
    end

    def memory(info)
      total, available = info["MemTotal"], info["MemAvailable"]
      return unless total && available && total > 0

      { total_bytes: total, available_bytes: available, used_percent: ((total - available) * 100.0 / total).round(1) }
    end

    def swap(info)
      { total_bytes: info["SwapTotal"], free_bytes: info["SwapFree"] } if info["SwapTotal"] && info["SwapFree"]
    end

    # `df -Pk`: a header, then "filesystem 1024-blocks used available capacity% mount".
    def disk(section)
      _, *numbers, capacity, mount = section.to_s.lines.last.to_s.split
      blocks, used, available = numbers.map { |number| Integer(number.to_s, 10, exception: false) }
      return unless numbers.size == 3 && blocks && used && available && capacity.to_s.match?(/\A\d+%\z/) && mount

      { mount: mount, total_bytes: blocks * KIB, used_bytes: used * KIB, available_bytes: available * KIB, used_percent: capacity.to_f }
    end
end
