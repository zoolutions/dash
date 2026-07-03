# Agent Orchestration Rules

## Available Agents

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| Explore | Codebase exploration | Finding files, tracing a call through the layer cake |
| Plan | Implementation planning | New CLI commands, cross-repo (gem + proxy) changes, upstream-sync conflicts |
| general-purpose | Multi-step tasks | Multi-file searches, research spanning `lib/` and `test/` |

## Immediate Agent Usage

Use agents PROACTIVELY without waiting for user prompt:

1. **New Thor command or config option** -> Plan agent first — it must touch `Cli`, `Configuration`, and matching `test/` files together
2. **"Where does X happen" questions** -> Explore agent — walk `Kamal::Cli::* -> Commander -> Commands::* -> Configuration -> SSHKit`
3. **Multi-file searches** -> Explore agent (not direct Glob/Grep) — e.g. every caller of `MINIMUM_VERSION`
4. **Upstream sync conflicts / release sequencing** -> Plan agent — see `.claude/rules/upstream-sync.md` before touching `proxy/run.rb` or `dash.gemspec`

## Parallel Execution

**ALWAYS** use parallel Task execution for independent operations:

```markdown
# GOOD: Parallel execution
Launch multiple agents simultaneously:
1. Agent 1: Explore lib/kamal/cli/proxy.rb + lib/kamal/commands/proxy.rb
2. Agent 2: Check lib/kamal/configuration/proxy/ for loadbalancer auto-activation
3. Agent 3: Review test/cli/proxy_test.rb + test/commands/proxy_test.rb coverage

# BAD: Sequential when unnecessary
First explore Cli, wait, then Commands, wait, then Configuration...
```

## When to Use Explore Agent

Use the Explore agent (subagent_type=Explore) instead of direct Glob/Grep when:
- Open-ended exploration across the layer cake (`bin/ -> Cli -> Commander -> Commands -> Configuration -> SSHKit`)
- Searching for patterns across `lib/kamal/cli/`, `lib/kamal/commands/`, `lib/kamal/configuration/`
- Answering "how does kamal do X" questions (e.g. how `deploy.yml` becomes a docker command)
- Finding every fork-owned divergence point (cross-check against the table in `CLAUDE.md`)

## When NOT to Use Agents

Use direct tools when:
- Reading a specific known file path (e.g. `lib/kamal/configuration/proxy/run.rb`)
- Simple pattern match in a known location
- Single-file edits (a Thor command tweak, a test assertion fix)
- Running `bin/test`, `bundle exec rubocop --parallel`, or `bin/release-dash`

## Repo-Specific Notes

- Two repos, one workflow: gem work here, proxy work in `../kamal-proxy` — never assume a single-repo change covers a proxy version bump. Cross-reference `../kamal-proxy/CLAUDE.md`.
- Unit-test-only exploration is fine without Docker; verifying integration behavior requires the full `bin/test` (Docker + published `ghcr.io/mhenrixon/kamal-proxy:$MINIMUM_VERSION`) — don't dispatch an agent to "run integration tests" unless that's actually available.
- Two builder tests are Apple-Silicon-only failures (host-arch dependent, pass in CI) — don't let an agent chase them as regressions.
- Before dispatching a Plan agent on anything touching `main`, remind it: `main` is fast-forward-only, never commit there.
