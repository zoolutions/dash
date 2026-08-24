# dash

**dash** (`zoolutions/dash`) — deploy web apps anywhere. Began as a fork of [basecamp/kamal](https://github.com/basecamp/kamal); made a clean break in 2026-08 (issue #115) and now moves independently — no upstream remote, no sync, no contributions back. Published on rubygems.org as `dash`; the executable is `dash`. The Ruby namespace is still `Kamal::` and on-server artifacts (`.kamal/`, `kamal-proxy` container, `KAMAL_*` env vars) keep their names until the staged renames ship (see Staged rename below).

## Tech Stack

- **Ruby**: 3.2–4.0 (CI matrix), Thor CLI, SSHKit + net-ssh, Zeitwerk
- **Gem**: `dash`, built from `dash.gemspec`
- **Proxy**: ghcr.io/zoolutions/dash-proxy (sibling repo `../kamal-proxy` → `zoolutions/dash-proxy`)
- **Testing**: minitest + mocha; integration tests run real deploys in Docker
- **Linting**: rubocop-rails-omakase

## Critical Rules

### Never Do

1. **NO pushing directly to `main`** — everything lands via PR (ruleset-enforced; admin bypass is for migrations, not routine)
2. **NO upstream syncs** — the fork network is left; basecamp code arrives only by deliberate cherry-pick, never via an `upstream` remote
3. **NO `-suffix` versions** like `v1.0.0-rc1` for the proxy — `Gem::Version` parses `-` as a prerelease, which sorts OLDER than the base and hard-fails `dash proxy boot`
4. **NO gem release before the proxy image exists** — the tag named by `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` must be pullable from `ghcr.io/zoolutions/dash-proxy` first (`rake release` gates on this)
5. **NO `git push --tags`** — single-tag pushes only; `rake release` creates the gem tag via `gh release create`
6. **NO rebasing published branches** — merge forward; history is shared
7. **NO renaming server artifacts yet** — `.kamal/`, the `kamal-proxy` container name, `KAMAL_*` env vars, the image title label, and the `Kamal::` namespace wait for the staged renames with a rolling-upgrade bridge

### Always Do

1. **Branch features off `main`**, PR back into `main`
2. **Interpolate `MINIMUM_VERSION` in test expectations** — never hardcode proxy versions
3. **Run unit tests + rubocop before pushing**; `bin/test` before merging

## Commands

```bash
bin/test                              # Full suite (integration needs Docker + published proxy image)
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests only
bundle exec rubocop --parallel        # Lint
rake release[3.2.0]                   # Release: version bump + tag v3.2.0 + GitHub release; CI trusted-publishes to RubyGems (Sigstore)
rake verify                           # Build the gem and list its contents
bin/sync-proxy-flags                  # Refresh the proxy flag manifest when MINIMUM_VERSION moves
```

## Architecture

```
Layer 5: bin/dash                  (entry point -> Kamal::Cli::Main)
Layer 4: Kamal::Cli::*             lib/kamal/cli (Thor commands, hooks)
Layer 3: Kamal::Commander          lib/kamal/commander.rb (KAMAL singleton, target resolution)
Layer 2: Kamal::Commands::*        lib/kamal/commands (docker command builders)
Layer 1: Kamal::Configuration      lib/kamal/configuration (deploy.yml -> objects, validation)
Layer 0: SSHKit                    (remote execution)
```

## The mental model

> `main` is the branch; a dash release is `main` plus a published dash-proxy image whose tag equals `MINIMUM_VERSION`. Proxy image first, gem second — always.

## Release flow

1. If the proxy changed or `MINIMUM_VERSION` must move: in `../kamal-proxy`, `script/release-dash v1.0.0.X` → CI publishes `ghcr.io/zoolutions/dash-proxy:v1.0.0.X` (multi-arch, must be PUBLIC); set `MINIMUM_VERSION` here and run `bin/sync-proxy-flags`.
2. `bin/test` (full suite).
3. `rake release[X.Y.Z]` — gates on the proxy image, bumps `lib/kamal/version.rb` + the `Gemfile.lock` pin, commits, pushes `main`, creates the `vX.Y.Z` GitHub release. The `release.yml` workflow then tests, builds, Sigstore-signs, and trusted-publishes to RubyGems (environment `rubygems`).

Gem tags are plain `vX.Y.Z` (own semver, 3.x line). Historical `dash-v*` tags are frozen. Proxy tags stay `v<base>.<n>` (or plain semver).

## Proxy image contract

- dash reads the running proxy version FROM THE IMAGE TAG (`docker inspect kamal-proxy --format '{{.Config.Image}}'`) and compares it with `Gem::Version` (`Kamal::Utils.older_version?`). Only the tag is compared, so old `kamal-proxy`-image containers upgrade cleanly to `dash-proxy` images.
- The image must carry the label `org.opencontainers.image.title=kamal-proxy` — `dash proxy remove` prunes by it (label rename waits for the bridge).
- Defaults live in `lib/kamal/configuration/proxy/run.rb` (`MINIMUM_VERSION`, repository `ghcr.io/zoolutions/dash-proxy`) and `lib/kamal/configuration/proxy/boot.rb` (legacy boot path).
- The old `ghcr.io/zoolutions/kamal-proxy` package stays published — gem versions < 3.2.0 pull it.

## Staged rename (issue #115 stages 2–3)

| Stage | Scope | Status |
|---|---|---|
| 1 | CLI executable + user-facing text + docs (`dash` only) | DONE (3.2.0) |
| 2 | Ruby namespace `Kamal::` → `Dash::`, `lib/kamal` → `lib/dash` | follow-up issue |
| 3 | Server artifacts: `.kamal/` → `.dash/`, `KAMAL_*` → `DASH_*`, container + label names — with a rolling-upgrade bridge | follow-up issue |

## Testing

- Unit: everything under `test/` except `test/integration` — no Docker needed. Two builder tests fail on Apple Silicon (host-arch dependent; they pass in CI).
- Integration: real deploys against Docker-in-Docker VMs; pulls `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION` — the tag must be published or the suite fails.
- CI: rubocop + actionlint/zizmor + Ruby 3.2–4.0 matrix on `main`.
- Multi-host fixtures with a >1-host primary role need `loadbalancer: false` under `proxy:` — the loadbalancer auto-activates and the dind harness can't support it.

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/lfg` | Full autonomous workflow: branch off `main` → understand → plan → TDD → verify → PR into `main` |
| `/plan` | Read-only planning → GitHub issue or `docs/plans/` markdown (execute with `/lfg`) |
| `/architect` | Coordinate multi-layer work across the Thor CLI → Commander → Commands → Configuration cake |
| `/tdd` | Enforce RED → GREEN → REFACTOR with Minitest + Mocha |
| `/security` | Audit SSH command construction, secret handling, shell escaping, error-page paths |
| `/perf` | Baseline vs `main` in a worktree — command construction only (dash has no bench suite) |
| `/review-pr` | Review a PR for pattern + project-constraint compliance |
| `/github-review-pr` | Full PR pass: fix CI failures, then process review comments |
| `/github-review-failures` | Diagnose + fix CI failures until green |
| `/github-review-comments` | Process unresolved PR review comments |
| `/finish-prs` | Drive a set of open PRs to merge-ready, one at a time |
| `/debug-flaky` | Root-cause an intermittent test failure — evidence → repro → stress-proofed fix; never skip/retry |

Commands pin a model tier via frontmatter aliases (`sonnet` implementation, `opus` orchestration/security/review, `fable` read-only planning) so they track the latest model per tier.

## More Documentation

- `ROADMAP.md` — evidence-linked improvement roadmap
- `.claude/rules/` — coding-style, git-workflow, testing, agents, performance, striving-for-excellence, upstream-sync (historical)
- `.claude/commands/` — the slash commands above
- Proxy repo: `../kamal-proxy/CLAUDE.md` — cross-repo release ordering
- Upstream kamal docs (shared basics): https://kamal-deploy.org
