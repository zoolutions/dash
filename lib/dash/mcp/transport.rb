# stdio, with the protocol on an IO of its own. dash prints from everywhere - SSHKit's
# formatter, `say`, hooks, warnings - and over stdio any line on stdout is a protocol
# frame, so the Runner points $stdout at $stderr and hands the real stdout here.
class Dash::Mcp::Transport < ::MCP::Server::Transports::StdioTransport
  def initialize(server, output:)
    super(server)
    @output = output
  end

  def send_response(message)
    @output.puts(message.is_a?(String) ? message : JSON.generate(message))
    @output.flush
  end
end
