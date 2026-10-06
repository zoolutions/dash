require_relative "mcp_test_case"

class McpLogsToolTest < McpTestCase
  test "is refused unless logs were allowed at boot" do
    text, error = call_tool("logs", { role: "web" })

    assert error
    assert_match "--allow-logs", text
  end

  test "tails the role when logs are allowed, and redacts what it returns" do
    SecureRandom.stubs(:hex).returns("0123456789abcdef")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("--dash-replica-0123456789abcdef--\ntoken=registry-secret-pw\nGET /up 200\n")

    logs = call_json("logs", { role: "web", hosts: [ "1.1.1.1" ], lines: 10, grep: "token" },
      on: server(session(allow_logs: true, secrets: { "PW" => "registry-secret-pw" })))

    assert_equal [ { "host" => "1.1.1.1", "replicas" => [ { "replica" => 1, "lines" => [ "token=[REDACTED]" ] } ] } ], logs["hosts"]
  end

  test "refuses a since that could run a command" do
    text, error = call_tool("logs", { since: "5m; reboot" }, on: server(session(allow_logs: true)))

    assert error
    assert_match "since must be a duration", text
  end

  test "refuses a role outside the server's scope" do
    text, error = call_tool("logs", { role: "workers" }, on: server(session(allow_logs: true, roles: [ "web" ])))

    assert error
    assert_match "No role workers within this server's scope (web)", text
  end

  test "honours DASH_MCP_ALLOW_LOGS" do
    assert Dash::Mcp::Runner.allow_logs?(false, "DASH_MCP_ALLOW_LOGS" => "true")
    assert_not Dash::Mcp::Runner.allow_logs?(false, "DASH_MCP_ALLOW_LOGS" => "nope")
    assert_not Dash::Mcp::Runner.allow_logs?(false, {})
  end
end
