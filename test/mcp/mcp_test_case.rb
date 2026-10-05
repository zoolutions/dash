require_relative "../diagnostics/diagnostics_test_case"

begin
  require "mcp"
  Dash::Mcp.load!
rescue Dash::ConfigurationError
  # Without the optional gem the MCP tests skip; CI has it from the development group.
end

class McpTestCase < DiagnosticsTestCase
  setup do
    skip "the mcp gem is not installed: add it to run test/mcp" unless defined?(::MCP::Tool)
  end

  private
    def session(fixture: :deploy_with_roles, secrets: {}, **options)
      Dash::Mcp::Session.new(config_file: Pathname.new(File.expand_path("../fixtures/#{fixture}.yml", __dir__)),
        redactor: Dash::Diagnostics::Redactor.new(secrets: secrets), **options)
    end

    def server(session = self.session)
      Dash::Mcp::Server.build(session)
    end

    # A tools/call over the protocol, as a client sends it. Returns [ result text, error? ].
    def call_tool(name, arguments = {}, on: server)
      response = JSON.parse(on.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json))
      result = response.fetch("result") { flunk "#{name} failed at the protocol level: #{response}" }

      [ result.dig("content", 0, "text"), result["isError"] ]
    end

    def call_json(name, arguments = {}, on: server)
      text, error = call_tool(name, arguments, on: on)
      assert_not error, "#{name} answered with an error: #{text}"

      JSON.parse(text)
    end
end
