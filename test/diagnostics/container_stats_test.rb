require_relative "diagnostics_test_case"

class DiagnosticsContainerStatsTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "joins each running container's labels with its resource use" do
    stub_capture "1.1.1.1", "docker stats", [
      ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"),
      "--%--",
      stats_line("aaaaaaaaaaaa", "app-web-999", cpu: "12.50%", mem: "120MiB / 1.9GiB", mem_percent: "6.17%", net: "1.2kB / 3.4MB", block: "0B / 8.19kB", pids: "23")
    ].join("\n")

    container = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first[:containers].first

    assert_equal [ "app-web-999", "web", 1, "999" ], container.values_at(:name, :role, :replica, :version)
    assert_equal({ cpu_percent: 12.5, memory_bytes: 120 * 1024**2, memory_limit_bytes: (1.9 * 1024**3).round, memory_percent: 6.17,
      net_rx_bytes: 1_200, net_tx_bytes: 3_400_000, block_read_bytes: 0, block_write_bytes: 8_190, pids: 23,
      raw: { cpu: "12.50%", memory: "120MiB / 1.9GiB", net_io: "1.2kB / 3.4MB", block_io: "0B / 8.19kB" } }, container[:stats])
  end

  test "a container that stopped between docker ps and docker stats keeps its labels, without stats" do
    stub_capture "1.1.1.1", "docker stats", [ ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"), "--%--", "" ].join("\n")

    container = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first[:containers].first

    assert_equal "app-web-999", container[:name]
    assert_nil container[:stats]
  end

  test "a host running nothing of this service reports nothing, and docker stats is never asked for everything" do
    captures = []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| captures << args.join(" "); true }.returns("--%--\n")

    assert_equal [ { host: "1.1.1.1", containers: [] } ], Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts]
    assert_includes captures.first, "| xargs -r docker stats"
  end

  test "a number docker printed in a way it cannot read stays as its raw string" do
    stub_capture "1.1.1.1", "docker stats",
      [ ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"), "--%--", stats_line("aaaaaaaaaaaa", "app-web-999", cpu: "--", mem: "-- / --") ].join("\n")

    stats = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first[:containers].first[:stats]

    assert_nil stats[:cpu_percent]
    assert_nil stats[:memory_bytes]
    assert_equal "--", stats[:raw][:cpu]
  end

  private
    def stats_line(id, name, cpu: "0.00%", mem: "0B / 0B", mem_percent: "0.00%", net: "0B / 0B", block: "0B / 0B", pids: "0")
      { "ID" => id, "Name" => name, "CPUPerc" => cpu, "MemUsage" => mem, "MemPerc" => mem_percent, "NetIO" => net, "BlockIO" => block, "PIDs" => pids }.to_json
    end
end
