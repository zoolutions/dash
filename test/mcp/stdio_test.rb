require_relative "mcp_test_case"
require "stringio"

# Over stdio every line on stdout is a protocol frame. dash prints from everywhere, so
# `dash mcp` hands stdout to the protocol alone and everything else goes to stderr.
class McpStdioTest < McpTestCase
  setup do
    @stdout, @stdin, @sshkit_output = $stdout, $stdin, SSHKit.config.output
  end

  teardown do
    $stdout, $stdin = @stdout, @stdin
    SSHKit.config.output = @sshkit_output
  end

  test "stdout carries only JSON-RPC, everything else lands on stderr" do
    Dash::Diagnostics::Containers.any_instance.stubs(:snapshot).with { puts "noise from inside a diagnostic"; true }.returns(hosts: [])

    stdout, stderr = run_mcp(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "containers", arguments: {} } })

    frames = stdout.lines.map { |line| JSON.parse(line) }
    assert_equal [ 1, 2, 3 ], frames.map { |frame| frame["id"] }
    assert frames.all? { |frame| frame["jsonrpc"] == "2.0" }
    assert_match "noise from inside a diagnostic", stderr
    assert_match "dash mcp: read-only diagnostics over stdio (logs off)", stderr
  end

  test "refuses to start when the token gate does not match" do
    with_env("DASH_MCP_TOKEN" => "expected", "DASH_MCP_AUTH_TOKEN" => "other") do
      assert_raises(Dash::ConfigurationError) { run_mcp }
    end
  end

  private
    def run_mcp(*requests)
      $stdin = StringIO.new(requests.map(&:to_json).join("\n") + "\n")
      stdout, stderr = StringIO.new, StringIO.new
      $stdout, original_stderr, $stderr = stdout, $stderr, stderr

      Dash::Cli::Main.start([ "mcp", "-c", "test/fixtures/deploy_with_roles.yml" ])

      [ stdout.string, stderr.string ]
    ensure
      $stderr = original_stderr
    end

    def with_env(vars)
      original = vars.keys.to_h { |name| [ name, ENV[name] ] }
      vars.each { |name, value| ENV[name] = value }
      yield
    ensure
      original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
end
