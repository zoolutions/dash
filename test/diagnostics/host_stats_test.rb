require_relative "diagnostics_test_case"

class DiagnosticsHostStatsTest < DiagnosticsTestCase
  LOADAVG = "0.52 0.48 0.40 2/345 6789"
  MEMINFO = "MemTotal:        4028424 kB\nMemAvailable:    2014212 kB\nSwapTotal:       1048572 kB\nSwapFree:         524286 kB"
  DF_ROOT = "Filesystem     1024-blocks    Used Available Capacity Mounted on\n/dev/sda1         82000000 41000000  41000000      50% /"
  DF_DOCKER = "Filesystem     1024-blocks    Used Available Capacity Mounted on\n/dev/sdb1         20000000 15000000   5000000      75% /var/lib/docker"

  setup do
    configure :deploy_with_roles
  end

  test "reads load, cpus, memory, swap, disk and uptime" do
    stub_capture "1.1.1.1", "/proc/loadavg", sections(LOADAVG, "2", MEMINFO, DF_ROOT, DF_DOCKER, "86400.25 170000.00")

    host = Dash::Diagnostics::HostStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first

    assert_equal "1.1.1.1", host[:host]
    assert_equal({ one: 0.52, five: 0.48, fifteen: 0.40, per_cpu: 0.26 }, host[:load])
    assert_equal 2, host[:cpus]
    assert_equal({ total_bytes: 4028424 * 1024, available_bytes: 2014212 * 1024, used_percent: 50.0 }, host[:memory])
    assert_equal({ total_bytes: 1048572 * 1024, free_bytes: 524286 * 1024 }, host[:swap])
    assert_equal({ mount: "/", total_bytes: 82000000 * 1024, used_bytes: 41000000 * 1024, available_bytes: 41000000 * 1024, used_percent: 50.0 }, host[:disk][:root])
    assert_equal "/var/lib/docker", host[:disk][:docker_root][:mount]
    assert_equal 75.0, host[:disk][:docker_root][:used_percent]
    assert_equal 86400, host[:uptime_seconds]
  end

  test "a host with docker down still reports everything else" do
    stub_capture "1.1.1.1", "/proc/loadavg", sections(LOADAVG, "2", MEMINFO, DF_ROOT, "df: '': No such file or directory", "86400.25 170000.00")

    host = Dash::Diagnostics::HostStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first

    assert_nil host[:disk][:docker_root]
    assert_equal 50.0, host[:disk][:root][:used_percent]
    assert_equal 2, host[:cpus]
  end

  test "a section it cannot read is nil, not a crash" do
    stub_capture "1.1.1.1", "/proc/loadavg", sections("", "", "", "", "", "")

    host = Dash::Diagnostics::HostStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first

    assert_equal({ host: "1.1.1.1", load: nil, cpus: nil, memory: nil, swap: nil, disk: { root: nil, docker_root: nil }, uptime_seconds: nil }, host)
  end

  test "an unreachable host is an error entry" do
    stub_unreachable "1.1.1.1", "/proc/loadavg"

    assert_match "ECONNREFUSED", Dash::Diagnostics::HostStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first[:error]
  end

  private
    def sections(*sections)
      sections.join("\n--%--\n") + "\n"
    end
end
