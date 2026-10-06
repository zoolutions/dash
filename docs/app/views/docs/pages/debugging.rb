# frozen_string_literal: true

# The --json inspection commands, the drift codes, and `dash mcp` — the read-only MCP
# server that lets an AI agent ask the same questions — with its security model first.
class Views::Docs::Pages::Debugging < DocsUI::Page
  title "Debugging"
  eyebrow "Deploying"

  def lead = "Ask a fleet what is running, what the proxies route to, and whether the two agree — as JSON from the CLI, or from an AI agent through dash mcp."

  JSON_COMMANDS = [
    [ "dash config --json", "The effective config (redacted) plus its topology: roles to hosts, proxied roles, proxy hosts, load balancer" ],
    [ "dash app containers --json", "Every container per host: role, replica slot, version, state, health, image" ],
    [ "dash proxy services [--json]", "What dash-proxy routes for this deploy on each proxy host, and on the load balancer" ],
    [ "dash proxy drift [--json]", "The containers compared with the proxy and load balancer targets" ],
    [ "dash doctor --json", "The readiness checks as {check, target, status, detail}; exits 1 when one fails" ],
    [ "dash audit --json", "The audit log per host, parsed into recorded_at, performer, tags, message" ],
    [ "dash lock status --json", "Whether the deploy lock is held, by whom, since when, why" ],
    [ "dash report show --json [--last N]", "The saved deploy reports, most recent first (at most 20)" ],
    [ "dash scale status --json", "Per role: replica bounds and each host's slots" ]
  ].freeze

  DRIFT_CODES = [
    [ "proxy_target_not_running", "dash-proxy routes to a container that is not running", "fail" ],
    [ "running_not_targeted", "a running container of a proxied role (any replica slot) is not a proxy target", "warn" ],
    [ "loadbalancer_target_missing", "a host the load balancer should forward to is not one of its targets", "fail" ],
    [ "loadbalancer_target_extra", "the load balancer forwards to a host no proxied role runs on", "warn" ],
    [ "version_mismatch", "the hosts of one role run different versions", "warn" ],
    [ "multiple_running_versions", "one host runs more than one version of a role", "warn" ]
  ].freeze

  TOOLS = [
    [ "config", "dash config --json" ],
    [ "containers", "dash app containers --json" ],
    [ "proxy_services", "dash proxy services --json" ],
    [ "drift", "dash proxy drift --json" ],
    [ "doctor", "dash doctor --json, without the registry check" ],
    [ "audit", "dash audit --json (lines: up to 500 per host)" ],
    [ "lock_status", "dash lock status --json" ],
    [ "deploy_reports", "dash report show --json (last: up to 20)" ],
    [ "logs", "dash app logs, off unless allowed (lines: up to 500, since, grep)" ],
    [ "scale_status", "dash scale status --json" ]
  ].freeze

  def content
    json_commands
    drift
    mcp_setup
    security_model
    operating_notes
  end

  private

  def json_commands
    DocsUI::Section("Inspection commands") do
      md <<~'MD'
        Each of these prints exactly one diagnostic as JSON on stdout — nothing
        else, so `| jq` works. Without `--json` the human output is unchanged.
        A host that cannot be reached is an entry with an `error`, not a
        failed command: the debugging tool keeps answering for the rest of
        the fleet exactly when one host is broken. None of them takes the
        deploy lock or changes a host.
      MD
      command_table JSON_COMMANDS
    end
  end

  def drift
    DocsUI::Section("Drift") do
      md <<~'MD'
        `dash proxy drift` answers "is the proxy pool consistent with what is
        running?" in one question. It reads the containers on every app host,
        the targets dash-proxy routes to on every proxy host, and the load
        balancer's targets, and reports each mismatch as
        `{code, host, role, detail}`. `dash doctor` runs the same check: the
        `fail` codes fail it, the rest warn.
      MD
      DocsUI::Table(
        [ "Code", "Means", "doctor" ],
        DRIFT_CODES.map { |code, means, doctor| [ [ :code, code ], means, doctor ] }
      )
      md <<~'MD'
        While the deploy lock is held, the two version codes are left out — a
        deploy in flight runs two versions on purpose — and the snapshot says
        `"lock_held": true`. A host whose containers or proxy routes could not
        be read is not compared: it is listed under `unread` with its error,
        the fleet is not reported consistent, and `dash doctor` warns.
      MD
    end
  end

  def mcp_setup
    DocsUI::Section("dash mcp") do
      md <<~'MD'
        `dash mcp` is a [Model Context Protocol](https://modelcontextprotocol.io)
        server over stdio. The agent's client (Claude Code, Cursor, …) starts
        it from the project directory, like any dash command, so it reads the
        same `deploy.yml`, `.dash/secrets` and SSH agent you do. It exposes the
        diagnostics above as tools — every one of them read-only:
      MD
      DocsUI::Table(
        [ "Tool", "Same answer as" ],
        TOOLS.map { |tool, same| [ [ :code, tool ], same ] }
      )
      md <<~'MD'
        The `mcp` gem is not a dash dependency — a deploy never needs it. Add
        it to the project's Gemfile:

        ```ruby
        gem "mcp", "~> 1.6", group: :development
        ```

        Then point the client at it. For Claude Code, `.mcp.json` in the
        project root:

        ```json
        {
          "mcpServers": {
            "dash-staging": {
              "command": "bundle",
              "args": ["exec", "dash", "mcp", "-d", "staging"]
            }
          }
        }
        ```

        Ask "is the proxy pool consistent?" and the agent answers from
        `drift`. The destination, config file, and the `--hosts` / `--roles`
        it starts with are fixed for the process; each question re-reads
        `deploy.yml`, so an edit shows up without a restart. The `pre-connect`
        hook runs once, at boot.

        | Option | Effect |
        |---|---|
        | `-d`, `--destination` | The destination, for the life of the process |
        | `-c`, `--config-file` | The config file |
        | `-h`, `--hosts` / `-r`, `--roles` / `-p` | A ceiling: a question can narrow inside it, never widen past it |
        | `--allow-logs` | Turn on the `logs` tool (or `DASH_MCP_ALLOW_LOGS=true`) |
      MD
    end
  end

  def security_model
    DocsUI::Section("Security model") do
      md <<~'MD'
        SSH authenticates dash to your hosts, and it stays the only way in:
        `dash mcp` listens on nothing, runs with your own SSH credentials, and
        can reach exactly what `dash` can. What SSH says nothing about are the
        three boundaries an agent adds — so `dash mcp` closes each one itself.

        **The agent → the remote shell.** A tool's arguments come from a
        model, which may be reading text an attacker wrote. Every argument is
        checked against the tool's schema (unknown arguments are refused),
        hosts and roles are looked up in the config so only configured names
        survive, `lines` is a bounded integer, `since` must look like `15m` or
        a timestamp, and `grep` is a substring match done in dash — it never
        reaches a shell. dash's test suite records every command each tool
        sends to a host and fails on anything outside a list of read-only
        shapes (`docker ps`, `dash-proxy list`, `tail`, `stat`/`cat` of the
        lock, `docker logs`, and the doctor's `docker version`, `docker
        inspect`, `docker manifest inspect`, `ss`). There is no deploy, scale,
        lock, reboot or exec tool. The doctor's registry check is left out
        because it runs `docker login` on every host.

        **Your hosts → the model provider.** Whatever a tool returns goes to
        the agent's model. Every response, and every error message, passes a
        redactor on its way out: any value under a key naming a credential
        (`password`, `token`, `secret`, `key` — deliberately broad, so
        `ssh_options.keys` is hidden too), and every value from `.dash/secrets`
        wherever it appears inside a string, so a password inside a
        `DATABASE_URL`, an audit line or an SSH error is blanked. Log lines are
        redacted before `grep` sees them, so a grep cannot probe a secret. Secrets
        shorter than 6 characters are only caught by their key. Container logs
        are off unless you start the server with `--allow-logs`: they carry
        whatever your app prints, personal data included, and the redactor only
        knows your secrets, not your users'.

        **Your hosts → the agent.** Audit lines, lock messages and logs are
        text other people wrote, and a model can mistake text for
        instructions. That cannot be filtered out reliably; the defence is
        that nothing the agent can call through `dash mcp` changes anything.
        The server tells the agent to treat tool output as data. Mind what
        other tools the same agent holds — a shell tool is not covered by any
        of this.

        **The token gate is not authentication.** When `DASH_MCP_TOKEN` is
        set, `dash mcp` refuses to start unless `DASH_MCP_AUTH_TOKEN` matches.
        Over stdio both come from whoever launches the process, so this only
        stops a launch nobody configured — a stray `.mcp.json`, a copied
        command — not a determined local user, who has your SSH agent anyway.
      MD
    end
  end

  def operating_notes
    DocsUI::Section("Operating notes") do
      md <<~'MD'
        - **Secrets resolve without a prompt.** stdin is the protocol, so a
          `.dash/secrets` command substitution that prompts (a password
          manager without a session) hangs the server. Sign in first. They are
          resolved once, at boot; restart after rotating one.
        - **stdout is the protocol.** Everything dash would print — SSHKit,
          hooks, warnings — goes to stderr, which MCP clients show as the
          server's log.
        - **The ceiling limits SSH, not the config.** `--hosts` keeps every
          question off other hosts, but the `config` tool still describes the
          whole topology. The deploy lock lives on the primary host, so
          `lock_status` refuses when the primary is outside the ceiling.
        - **Large fleets:** narrow per question with `hosts` / `roles`, and
          `audit` / `logs` read at most 500 lines per host.
      MD
    end
  end

  def command_table(rows)
    DocsUI::Table(
      [ "Command", "What it prints" ],
      rows.map { |command, description| [ [ :code, command ], description ] }
    )
  end
end
