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
    dash/mcp/server
    dash/mcp/transport
    dash/mcp/runner
  ].freeze

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
