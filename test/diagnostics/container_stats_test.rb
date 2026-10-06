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
      raw: { cpu: "12.50%", memory: "120MiB / 1.9GiB", memory_percent: "6.17%", net_io: "1.2kB / 3.4MB", block_io: "0B / 8.19kB", pids: "23" } }, container[:stats])
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
    assert_includes captures.first, "|| echo #{Dash::Commands::App::ACTIVE_CONTAINERS_UNREADABLE}"
  end

  test "a host whose docker cannot be asked is an error, not a host running nothing" do
    stub_capture "1.1.1.1", "docker stats", "#{Dash::Commands::App::ACTIVE_CONTAINERS_UNREADABLE}\n--%--\n"

    host = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ], accessories: []).to_h[:hosts].first

    assert_nil host[:containers]
    assert_match "docker ps failed: the docker daemon could not be asked", host[:error]
  end

  test "a docker stats that fails keeps the containers and says the sample failed" do
    stub_capture "1.1.1.1", "docker stats",
      [ ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"), "--%--", Dash::Diagnostics::ContainerStats::STATS_UNREADABLE ].join("\n")

    host = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ], accessories: []).to_h[:hosts].first

    assert_equal "app-web-999", host[:containers].first[:name]
    assert_nil host[:containers].first[:stats]
    assert_match "docker stats failed", host[:stats_error]
  end

  test "a NaN sample docker printed does not break the JSON" do
    stub_capture "1.1.1.1", "docker stats",
      [ ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"), "--%--", stats_line("aaaaaaaaaaaa", "app-web-999", cpu: "NaN%", mem_percent: "NaN%") ].join("\n")

    snapshot = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ], accessories: []).to_h

    assert_nil snapshot[:hosts].first[:containers].first[:stats][:cpu_percent]
    assert_nothing_raised { JSON.generate(snapshot) }
  end

  test "a number docker printed in a way it cannot read stays as its raw string" do
    stub_capture "1.1.1.1", "docker stats",
      [ ps_line("app-web-999", id: "aaaaaaaaaaaa", role: "web"), "--%--", stats_line("aaaaaaaaaaaa", "app-web-999", cpu: "--", mem: "-- / --") ].join("\n")

    stats = Dash::Diagnostics::ContainerStats.new(hosts: [ "1.1.1.1" ]).to_h[:hosts].first[:containers].first[:stats]

    assert_nil stats[:cpu_percent]
    assert_nil stats[:memory_bytes]
    assert_equal "--", stats[:raw][:cpu]
  end

  test "reports each accessory on its own hosts" do
    configure :deploy_with_accessories
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("--%--\n")
    mysql = { "ID" => "mmmmmmmmmmmm", "Names" => "app-mysql", "Image" => "mysql:5.7", "State" => "running", "Status" => "Up 3 days", "Labels" => "service=app-mysql" }.to_json
    stub_capture "1.1.1.3", "label=service=app-mysql", [ mysql, "--%--", stats_line("mmmmmmmmmmmm", "app-mysql", cpu: "3.00%", mem: "400MiB / 1GiB", pids: "40") ].join("\n")

    accessories = Dash::Diagnostics::ContainerStats.new.to_h[:accessories]

    mysql_entry = accessories.find { |entry| entry[:accessory] == "mysql" }
    assert_equal "1.1.1.3", mysql_entry[:host]
    container = mysql_entry[:containers].first
    assert_equal [ "app-mysql", "mysql" ], container.values_at(:name, :accessory)
    assert_equal [ 3.0, 40 ], container[:stats].values_at(:cpu_percent, :pids)
    assert_equal [ "1.1.1.1", "1.1.1.2" ], accessories.select { |entry| entry[:accessory] == "redis" }.map { |entry| entry[:host] }
  end

  private
    def stats_line(id, name, cpu: "0.00%", mem: "0B / 0B", mem_percent: "0.00%", net: "0B / 0B", block: "0B / 0B", pids: "0")
      # Every key `docker stats --format '{{json .}}'` prints (docker/cli formatter_stats.go):
      # ID is the 12-character short ID, Container what the command was given - here the ID.
      { "BlockIO" => block, "CPUPerc" => cpu, "Container" => id, "ID" => id, "MemPerc" => mem_percent, "MemUsage" => mem,
        "Name" => name, "NetIO" => net, "PIDs" => pids }.to_json
    end
end
