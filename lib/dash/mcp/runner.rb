require "active_support/security_utils"

# Boots `dash mcp`: the token gate, the logs gate, the stdio loop.
module Dash::Mcp::Runner
  TRUTHY = %w[ 1 true yes on ].freeze

  module_function

  # Not authentication: the client that launches `dash mcp` sets both variables, so this
  # only stops a launch nobody configured for it (a stray .mcp.json, a copied command).
  # The boundary is the operator's own SSH credentials. No-op unless DASH_MCP_TOKEN is set.
  def authorize!(env)
    expected = env["DASH_MCP_TOKEN"]
    return if expected.blank?
    return if env["DASH_MCP_AUTH_TOKEN"] && ActiveSupport::SecurityUtils.secure_compare(expected, env["DASH_MCP_AUTH_TOKEN"])

    raise Dash::ConfigurationError, "dash mcp: DASH_MCP_TOKEN is set, so DASH_MCP_AUTH_TOKEN must match it"
  end

  def allow_logs?(flag, env)
    flag || TRUTHY.include?(env["DASH_MCP_ALLOW_LOGS"].to_s.strip.downcase)
  end

  def run(session, output:)
    $stderr.puts "dash mcp: read-only diagnostics over stdio (logs #{session.allow_logs? ? "ALLOWED" : "off"})"
    Dash::Mcp::Transport.new(Dash::Mcp::Server.build(session), output: output).open
  end
end
