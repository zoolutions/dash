# `dash mcp`: read-only diagnostics for an AI agent over the Model Context Protocol.
#
# Kept out of Zeitwerk (lib/dash.rb ignores lib/dash/mcp/) because the tools subclass
# `MCP::Tool` from the optional `mcp` gem, which a deploy should never need. This file
# stays autoloadable so `dash mcp` can say what to install; `load!` pulls in the rest.
module Dash::Mcp
  module Tools; end

  REQUIRES = %w[
    dash/mcp/session
    dash/mcp/base_tool
    dash/mcp/tools/config_tool
    dash/mcp/tools/containers_tool
    dash/mcp/tools/proxy_services_tool
    dash/mcp/tools/drift_tool
    dash/mcp/tools/deploy_reports_tool
    dash/mcp/tools/audit_tool
    dash/mcp/tools/lock_status_tool
    dash/mcp/tools/doctor_tool
    dash/mcp/tools/logs_tool
    dash/mcp/tools/scale_status_tool
    dash/mcp/tools/pool_members_tool
    dash/mcp/tools/autoscale_explain_tool
    dash/mcp/tools/autoscale_decisions_tool
    dash/mcp/tools/controller_status_tool
    dash/mcp/tools/container_stats_tool
    dash/mcp/tools/host_stats_tool
    dash/mcp/server
    dash/mcp/transport
    dash/mcp/runner
  ].freeze

  # Everything that prints after this lands on stderr; the returned IO carries only the
  # protocol. `dash mcp` calls it first, before even the gem loads, so nothing - not the
  # "add the gem" error either - can print onto the protocol stream.
  def self.reserve_stdout!
    protocol = $stdout
    protocol.set_encoding("UTF-8")
    $stdout = $stderr
    SSHKit.config.output = SSHKit::Formatter::Pretty.new($stderr)
    protocol
  end

  # Only the gem's own require is rescued, so a broken dash/mcp/* require shows up as
  # itself instead of as "add the gem".
  def self.load!
    begin
      require "mcp"
    rescue LoadError
      raise Dash::ConfigurationError, "dash mcp needs the `mcp` gem: add `gem \"mcp\", \"~> 1.6\"` to your Gemfile and run `bundle install`"
    end

    REQUIRES.each { |path| require path }
  end
end
