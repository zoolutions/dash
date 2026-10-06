require "json"

# Every dash MCP tool: read-only by annotation, answered through the Session, and
# redacted at this boundary so a tool author cannot leak a secret by forgetting to.
#
# Write tools (scale, deploy, lock, reboot, exec) are out of scope. If they ever exist
# they get their own opt-in surface and never inherit from this class.
class Dash::Mcp::BaseTool < ::MCP::Tool
  annotations read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false

  # The filters every SSH-backed tool takes. Values are matched against the configured
  # hosts and roles, so nothing an agent passes reaches a shell.
  SCOPE = {
    hosts: { type: "array", items: { type: "string" }, description: "Only these hosts (* wildcards allowed), within the server's --hosts" },
    roles: { type: "array", items: { type: "string" }, description: "Only these roles (* wildcards allowed), within the server's --roles" }
  }.freeze

  class << self
    # MCP::Tool.inherited resets the annotations on every subclass; fall back to the
    # nearest ancestor's so the read-only contract reaches every tool.
    def annotations_value
      super || (superclass.annotations_value if superclass.respond_to?(:annotations_value))
    end

    def answer(server_context, hosts: nil, roles: nil, &question)
      session = server_context.fetch(:session)
      json_response(session.answer(hosts: hosts, roles: roles, &question), session.redactor)
    rescue ArgumentError, Dash::ConfigurationError, Psych::SyntaxError => e
      error_response(session.redactor.redact_text(e.message))
    rescue StandardError => e
      # An SSHKit failure's message carries the whole command and its stderr.
      error_response(session.redactor.redact_text("#{e.class}: #{e.message}"))
    end

    def json_response(value, redactor)
      ::MCP::Tool::Response.new([ { type: "text", text: JSON.generate(redactor.redact(value)) } ])
    end

    def error_response(message)
      ::MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
    end
  end
end
