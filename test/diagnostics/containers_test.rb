require_relative "diagnostics_test_case"

class DiagnosticsContainersTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "lists every container per host with role, slot, version and health" do
    stub_capture "1.1.1.1", "{{json .}}", [ ps_line("app-web-999", id: "aaa", role: "web"), ps_line("app-web-998", id: "bbb", role: "web", state: "exited", status: "Exited (0) 1 hour ago") ].join("\n")
    stub_capture "1.1.1.2", "{{json .}}", ""
    stub_capture "1.1.1.3", "{{json .}}", ps_line("app-workers-999", id: "ccc", role: "workers", status: "Up 1 hour")
    stub_capture "1.1.1.4", "{{json .}}", ""

    snapshot = Dash::Diagnostics::Containers.new.to_h

    assert snapshot[:generated_at]
    assert_equal %w[ 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 ], snapshot[:hosts].map { |host| host[:host] }

    web = snapshot[:hosts].first[:containers]
    assert_equal [ "app-web-999", "app-web-998" ], web.map { |container| container[:name] }
    assert_equal({ name: "app-web-999", id: "aaa", role: "web", replica: 1, version: "999", state: "running",
      status: "Up 2 hours (healthy)", health: "healthy", image: "dhh/app:999", created_at: "2026-10-05 10:00:00 +0000 UTC" }, web.first)
    assert_nil snapshot[:hosts][2][:containers].first[:health]
    assert_equal [], snapshot[:hosts][1][:containers]
  end

  test "an unreachable host is an error entry, not an exception" do
    stub_capture "1.1.1.1", "{{json .}}", ""
    stub_unreachable "1.1.1.2", "{{json .}}"
    stub_capture "1.1.1.3", "{{json .}}", ""
    stub_capture "1.1.1.4", "{{json .}}", ""

    hosts = Dash::Diagnostics::Containers.new.to_h[:hosts]

    assert_equal({ host: "1.1.1.2", error: "Errno::ECONNREFUSED: Connection refused" }, hosts[1])
    assert_equal [], hosts[0][:containers]
  end

  test "a label value with a comma does not cost the host its answer" do
    line = { "ID" => "aaa", "Names" => "app-web-999", "State" => "running", "Status" => "Up",
             "Labels" => "traefik.http.routers.app.rule=Host(a,b),role=web,service=app" }.to_json
    stub_capture "1.1.1.1", "{{json .}}", line
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| SSHKit::Backend.current.host.to_s != "1.1.1.1" }.returns("")

    container = Dash::Diagnostics::Containers.new.to_h[:hosts].first[:containers].first

    assert_equal [ "web", 1, "999" ], container.values_at(:role, :replica, :version)
  end

  test "lists each accessory's container on its own hosts" do
    configure :deploy_with_accessories
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    stub_capture "1.1.1.3", "label=service=app-mysql",
      { "ID" => "mmm", "Names" => "app-mysql", "Image" => "mysql:5.7", "State" => "exited", "Status" => "Exited (1) 2 minutes ago", "Labels" => "service=app-mysql" }.to_json

    mysql = Dash::Diagnostics::Containers.new.to_h[:accessories].find { |entry| entry[:accessory] == "mysql" }

    assert_equal({ host: "1.1.1.3", accessory: "mysql", containers: [ { name: "app-mysql", id: "mmm", accessory: "mysql", state: "exited",
      status: "Exited (1) 2 minutes ago", health: nil, image: "mysql:5.7", created_at: nil } ] }, mysql)
  end

  test "is JSON-safe" do
    stub_capture "1.1.1.1", "{{json .}}", ps_line("app-web-999", id: "aaa", role: "web")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| SSHKit::Backend.current.host.to_s != "1.1.1.1" }.returns("")

    snapshot = Dash::Diagnostics::Containers.new.to_h

    assert_equal JSON.parse(snapshot.to_json), snapshot.deep_stringify_keys
  end
end
