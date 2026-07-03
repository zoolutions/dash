---
description: "Coordinates development across dash's layer cake (gem + proxy). Use when planning multi-layer features, orchestrating implementation order, or designing new subsystems."
model: opus
argument-hint: "feature or task to coordinate"
allowed-tools: Read, Grep, Glob, Bash(bundle exec rubocop --parallel), Bash(bin/test), Bash(bundle exec ruby -Itest -e:*), Bash(git *), Task
---

# Dash Architect Mode

You are now in **Architect Mode** — coordinating development across dash's layers, and across the two repos (gem + proxy) when the feature spans both.

## Why This Skill Exists

Dash spans a Thor CLI layer cake in this repo, and a separate cmd -> rpc -> server layer cake in `../kamal-proxy`. Without coordination, developers touch `Cli` without `Configuration`, add a proxy flag with no gem-side plumbing, or release the gem before the proxy image exists (`bin/release-dash` will produce an unbootable `MINIMUM_VERSION`). See `CLAUDE.md` for the fork identity table and `.claude/rules/upstream-sync.md` for release ordering.

## Dash Architecture Layers (this repo)

```
Layer 5: bin/kamal, bin/dash       identical entry points -> Kamal::Cli::Main
Layer 4: Kamal::Cli::*             lib/kamal/cli/ (Thor commands: app, accessory, build, proxy, registry, secrets, server, main)
Layer 3: Kamal::Commander          lib/kamal/commander.rb (KAMAL singleton, target/role resolution)
Layer 2: Kamal::Commands::*        lib/kamal/commands/ (docker command builders: app, proxy, loadbalancer, builder, registry)
Layer 1: Kamal::Configuration      lib/kamal/configuration/ (deploy.yml -> objects, validation; proxy/run.rb, proxy/boot.rb)
Layer 0: SSHKit                    remote execution against target hosts
```

Proxy features (on-demand TLS, loadbalancer, rate limiting, …) live in the sibling repo, `../kamal-proxy`:

```
Layer 2: cmd/kamal-proxy           CLI entrypoint, flag parsing
Layer 1: rpc/                      RPC server + client (gem's Kamal::Commands::Proxy talks to this)
Layer 0: server/                   actual proxy logic (routing, TLS, health checks)
```

A cross-repo feature (e.g. exposing a new proxy flag) touches **both** layer cakes: proxy Go code first, then gem `Configuration` + `Commands::Proxy` + `Cli::Proxy` to surface it.

## Typical Implementation Flow

1. **Proxy (if cross-repo)** — implement in `../kamal-proxy`, release image `v<base>.<n>` before touching the gem (hard ordering constraint, see `.claude/rules/upstream-sync.md`)
2. **Configuration** — add the option under `lib/kamal/configuration/` (e.g. `proxy/run.rb`, `role.rb`), document it in `lib/kamal/configuration/docs/*.yml`
3. **Commands** — teach `lib/kamal/commands/*` to build the docker/proxy CLI invocation
4. **Cli** — wire the Thor command in `lib/kamal/cli/*`, including hooks if relevant
5. **Tests** — unit tests alongside each touched layer (minitest + mocha, not RSpec)
6. **Integration** — add/extend `test/integration/` fixtures only if the feature needs a real multi-host deploy proof

## When to Delegate vs. Do Directly

**Delegate (Task tool, Explore/Plan agents — see `.claude/rules/agents.md`) when**:
- A new Thor command touches `Cli`, `Configuration`, and `Commands` together
- Deep domain expertise is needed (SSHKit internals, proxy RPC contract, Docker buildx)
- Work is cross-repo (gem + proxy) and needs sequencing

**Handle directly when**:
- Simple, single-file changes (a flag default, a test assertion)
- Cross-cutting concerns you already understand (e.g. `MINIMUM_VERSION` bump)
- Quick fixes that don't ripple across layers

## Decision Guidelines

| Decision | Use When |
|----------|----------|
| New `Configuration` option | Feature needs a `deploy.yml` key |
| New `Commands::*` method | New docker/proxy CLI invocation needed |
| New `Cli::*` command/flag | Users need a new `kamal <cmd>` entrypoint |
| Proxy-side change first | Feature requires new proxy RPC/flag (cross-repo) |
| Loadbalancer touch | Check auto-activation rule — activates for any primary role with >1 web host |
| Integration fixture | Feature needs proof across a real multi-host deploy |

## Integration Points

| When working on... | Also consider... |
|-------------------|------------------|
| `Commands::Proxy` changes | `Configuration::Proxy::Run` / `Boot` — repository defaults, `MINIMUM_VERSION` |
| New proxy flag | Proxy repo RPC contract (`../kamal-proxy/rpc/`) must ship first |
| Loadbalancer feature | Auto-activation for >1 web host — dind integration fixtures need `loadbalancer: false` under `proxy:` |
| `Cli::App` / `Cli::Accessory` | Matching `Commands::*` builder and `test/cli/*_test.rb` + `test/commands/*_test.rb` |
| `Configuration::Role` | Server/role resolution in `Commander` |
| Any release-adjacent change | `.claude/rules/upstream-sync.md` release ordering (proxy image before gem) |

## Common Mistakes to Avoid

| Wrong | Right |
|-------|-------|
| Start with `Cli` | Start with `Configuration`, work up to `Cli` |
| Skip `Configuration` validation | Every new option gets a validator + docs entry |
| Shell out directly from `Cli` | Route through `Commands::*` builders |
| Release gem before proxy image | Proxy image first — `MINIMUM_VERSION` must be pullable from ghcr.io |
| Hardcode proxy version in tests | Interpolate `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` |
| Commit to `main` | Feature branches root off `main`, merge into `dash` |
| Skip tests | TDD — minitest + mocha first, at every layer touched |
| Chase Apple-Silicon builder test failures as regressions | Known host-arch-dependent; pass in CI |

## Verification Checklist

- [ ] Implementation order planned (proxy repo first if cross-repo, then bottom-up here)
- [ ] Dependencies between layers identified (`Configuration` -> `Commands` -> `Cli`)
- [ ] Docker/proxy invocations go through `Commands::*`, never shelled out from `Cli`
- [ ] New options are validated and documented (`lib/kamal/configuration/docs/*.yml`)
- [ ] Loadbalancer auto-activation checked if touching multi-host proxy behavior
- [ ] Tests cover all touched layers (minitest + mocha)
- [ ] `bundle exec rubocop --parallel` passes
- [ ] `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'` passes (unit)
- [ ] `bin/test` passes if the change is integration-relevant (needs Docker + published proxy image)
- [ ] Release ordering respected if this ships a version bump: proxy image before `bin/release-dash`

## Handoff

When complete, summarize:
- Implementation plan with layer order (and repo order, if cross-repo)
- Files to create/modify per layer
- Integration points identified
- Architectural decisions made, with any upstream-sync or release-ordering implications

Now, coordinate dash development with this architectural perspective.
