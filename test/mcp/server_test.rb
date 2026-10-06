require_relative "mcp_test_case"

class McpServerTest < McpTestCase
  test "lists exactly the curated tools" do
    response = JSON.parse(server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json))

    assert_equal %w[ audit config container_stats containers deploy_reports doctor drift host_stats lock_status logs pool_members proxy_services scale_status ],
      response.dig("result", "tools").map { |tool| tool["name"] }.sort
  end

  test "every tool is read-only, non-destructive and idempotent" do
    Dash::Mcp::Server::TOOLS.each do |tool|
      annotations = tool.annotations_value.to_h

      assert_equal true, annotations[:readOnlyHint], "#{tool.tool_name} is not read-only"
      assert_equal false, annotations[:destructiveHint], "#{tool.tool_name} is destructive"
      assert_equal true, annotations[:idempotentHint], "#{tool.tool_name} is not idempotent"
    end
  end

  test "no tool is named for something that changes state" do
    assert_empty Dash::Mcp::Server::TOOLS.map(&:tool_name).grep(/deploy\z|scale(?!_status\z)|exec|reboot|restart|remove|stop|start|acquire|release|prune|rollback/)
  end

  test "an argument a tool does not declare is refused" do
    text, error = call_tool("containers", { "command" => "rm -rf /" })

    assert error
    assert_match "command", text
  end

  test "answers a tool call over the protocol" do
    config = call_json("config")

    assert_equal [ "web", "workers" ], config["roles"].map { |role| role["name"] }
  end
end
