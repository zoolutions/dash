require_relative "mcp_test_case"

class McpRunnerTest < McpTestCase
  test "the token gate is open when no token is configured" do
    assert_nothing_raised { Dash::Mcp::Runner.authorize!({}) }
  end

  test "the token gate needs a matching auth token" do
    assert_nothing_raised { Dash::Mcp::Runner.authorize!("DASH_MCP_TOKEN" => "s3cret", "DASH_MCP_AUTH_TOKEN" => "s3cret") }
    assert_raises(Dash::ConfigurationError) { Dash::Mcp::Runner.authorize!("DASH_MCP_TOKEN" => "s3cret", "DASH_MCP_AUTH_TOKEN" => "wrong") }
    assert_raises(Dash::ConfigurationError) { Dash::Mcp::Runner.authorize!("DASH_MCP_TOKEN" => "s3cret") }
  end
end
