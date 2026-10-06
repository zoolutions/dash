require_relative "mcp_test_case"

class McpSessionTest < McpTestCase
  setup do
    @seen = []
    Dash::Diagnostics::Containers.any_instance.stubs(:snapshot).with { @seen << DASH.hosts.dup; true }.returns(hosts: [])
  end

  test "one call's hosts filter does not leak into the next" do
    server = self.server

    call_json("containers", { hosts: [ "1.1.1.1" ] }, on: server)
    call_json("containers", {}, on: server)

    assert_equal [ [ "1.1.1.1" ], [ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ] ], @seen
  end

  test "a call narrows by role" do
    call_json("containers", { roles: [ "workers" ] })

    assert_equal [ [ "1.1.1.3", "1.1.1.4" ] ], @seen
  end

  test "the boot-time hosts are a ceiling a call cannot widen" do
    server = self.server(session(hosts: [ "1.1.1.1", "1.1.1.2" ]))

    call_json("containers", {}, on: server)
    call_json("containers", { hosts: [ "1.1.1.2" ] }, on: server)
    text, error = call_tool("containers", { hosts: [ "1.1.1.3" ] }, on: server)

    assert_equal [ [ "1.1.1.1", "1.1.1.2" ], [ "1.1.1.2" ] ], @seen
    assert error
    assert_match "No hosts match 1.1.1.3 within this server's scope (1.1.1.1,1.1.1.2)", text
  end

  test "the boot-time roles are a ceiling a call cannot widen" do
    server = self.server(session(roles: [ "web" ]))

    text, error = call_tool("containers", { roles: [ "workers" ] }, on: server)

    assert error
    assert_match "No roles match workers within this server's scope (web)", text
  end

  test "re-reads deploy.yml per call but keeps the pre-connect hook from firing again" do
    DASH.connected = true
    Dash::Commander.any_instance.expects(:reconfigure).twice.with { |**kwargs| kwargs[:config_file].to_s.end_with?("deploy_with_roles.yml") }

    session = self.session
    2.times { session.answer { } }

    assert DASH.connected?
  end

  test "host_stats narrows by role, through the same scope as every other tool" do
    seen = []
    Dash::Diagnostics::HostStats.any_instance.stubs(:snapshot).with { seen << DASH.hosts.dup; true }.returns(hosts: [])

    call_json("host_stats", { roles: [ "workers" ] })

    assert_equal [ [ "1.1.1.3", "1.1.1.4" ] ], seen
  end

  test "scale_status answers per role within the call's roles" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("app-payments-123\tUp 2 hours\n")

    scale = call_json("scale_status", { roles: [ "payments" ] }, on: server(session(fixture: :deploy_with_replicas)))

    assert_equal [ "payments" ], scale["roles"].map { |role| role["role"] }
    assert_equal 2, scale["roles"].first["total"]
  end

  test "the lock is read from the primary host only when it is in scope" do
    text, error = call_tool("lock_status", {}, on: server(session(hosts: [ "1.1.1.2" ])))

    assert error
    assert_match "lives on the primary host 1.1.1.1, outside this server's --hosts", text
  end
end
