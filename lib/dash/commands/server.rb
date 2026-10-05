class Dash::Commands::Server < Dash::Commands::Base
  def remove_app_directory
    remove_directory config.app_directory
  end

  def app_directory_count
    pipe \
      [ :ls, config.apps_directory ],
      [ :wc, "-l" ]
  end

  SECTION_SEPARATOR = "--%--"

  # Load, CPU count, memory, disk for / and Docker's data root, and uptime, one section
  # each in one round trip. getconf rather than nproc and df -Pk rather than -B1, so a
  # busybox host answers too.
  def stats
    sections = [
      [ :cat, "/proc/loadavg" ],
      [ :getconf, "_NPROCESSORS_ONLN" ],
      [ :grep, "-E", "'^(MemTotal|MemAvailable|SwapTotal|SwapFree):'", "/proc/meminfo" ],
      [ :df, "-Pk", "/" ],
      [ :df, "-Pk", %("$(docker info --format '{{.DockerRootDir}}')") ],
      [ :cat, "/proc/uptime" ]
    ]

    chain(*sections.flat_map { |section| [ section, [ :echo, SECTION_SEPARATOR ] ] }[0...-1])
  end

  # Lists TCP listeners on the given port, one line per listener, no header.
  def listeners_on(port)
    [ :ss, "-ltnH", :sport, "=", ":#{port}" ]
  end
end
