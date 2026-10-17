# dash

Project instructions for every agent: Claude Code (`CLAUDE.md` imports this file), Grok, Cursor,
Copilot, Codex. Claude-only extras (commands, settings) live under `.claude/`; the workflow itself is the `flow` plugin.

**dash** (`zoolutions/dash`) — deploy web apps anywhere. Began as a fork of [basecamp/kamal](https://github.com/basecamp/kamal); made a clean break in 2026-08 (issue #115) and now moves independently — no upstream remote, no sync, no contributions back. Published on rubygems.org as `dash`; the executable is `dash` and the Ruby namespace is `Dash::` (stage 2, issue #117). The server run directory is `.dash/` as of stage 3b; the remaining on-server artifacts (`kamal-proxy` container, `kamal` network, `KAMAL_*` env vars) keep their names until stage 3c ships (see Staged rename below).

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
4. **NO gem release before the proxy image exists** — the tag named by `Dash::Configuration::Proxy::Run::MINIMUM_VERSION` must be pullable from `ghcr.io/zoolutions/dash-proxy` first (`rake release` gates on this)
5. **NO `git push --tags`** — single-tag pushes only; `rake release` creates the gem tag via `gh release create`
6. **NO rebasing published branches** — merge forward; history is shared
7. **NO renaming the remaining server artifacts yet** — the `kamal-proxy` container name, the `kamal` docker network, the `kamal-proxy-config` / `kamal-loadbalancer-config` volumes, `KAMAL_*` env vars, and the image title label wait for stage 3c and a coordinated dash-proxy release. The run directory (`.dash/`) and config-digest label landed in 3b.

### Always Do

1. **Branch features off `main`**, PR back into `main`
2. **Interpolate `MINIMUM_VERSION` in test expectations** — never hardcode proxy versions
3. **Run unit tests + rubocop before pushing**; `bin/test` before merging

## Commands

```bash
bin/test                              # Full suite (integration needs Docker + published proxy image)
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests only
bundle exec rubocop --parallel        # Lint
bin/release [patch|minor|major|X.Y.Z] # Release: previews the bump + changelog, confirms, then runs rake release (`list`, `--dry-run`, `--force`)
rake release[3.2.0]                   # Release (low-level): version bump + tag v3.2.0 + GitHub release; CI trusted-publishes to RubyGems (Sigstore)
rake verify                           # Build the gem and list its contents
bin/sync-proxy-flags                  # Refresh the proxy flag manifest when MINIMUM_VERSION moves
```

Command output is condensed by rtk (PreToolUse hook). `.rtk/filters.toml` covers this repo's
`bundle exec ruby -Itest` unit-test run and `rake verify` (both shell out to a second Ruby
process that duplicate-loads `rdoc`/`Gem::Platform`, which is pure noise); every edit to it needs
`rtk trust --yes` + `rtk verify`. Write commands in hook-rewritable shapes: no `for`/subshell
wrappers, no `| head` on rtk-handled commands, `bundle exec rubocop` not `bin/rubocop`.

## Architecture

```
Layer 5: bin/dash                  (entry point -> Dash::Cli::Main)
Layer 4: Dash::Cli::*             lib/dash/cli (Thor commands, hooks)
Layer 3: Dash::Commander          lib/dash/commander.rb (DASH singleton, target resolution)
Layer 2: Dash::Commands::*        lib/dash/commands (docker command builders)
Layer 1: Dash::Configuration      lib/dash/configuration (deploy.yml -> objects, validation)
Layer 0: SSHKit                    (remote execution)
```

## The mental model

> `main` is the branch; a dash release is `main` plus a published dash-proxy image whose tag equals `MINIMUM_VERSION`. Proxy image first, gem second — always.

## Release flow

1. If the proxy changed or `MINIMUM_VERSION` must move: in `../kamal-proxy`, `script/release-dash v1.0.0.X` → CI publishes `ghcr.io/zoolutions/dash-proxy:v1.0.0.X` (multi-arch, must be PUBLIC); set `MINIMUM_VERSION` here and run `bin/sync-proxy-flags`.
2. `bin/test` (full suite).
3. `bin/release [patch|minor|major|X.Y.Z]` — computes the next version from `lib/dash/version.rb`, shows the commits since the last tag, requires a clean, up-to-date `main`, and asks for confirmation before running `rake release[X.Y.Z]` (`rakelib/release.rake`), which gates on the proxy image (the `release:preflight` hook in the `Rakefile`), bumps `lib/dash/version.rb` + the `dash` pin in `Gemfile.lock` and `docs/Gemfile.lock` (in place, no re-resolve), commits, pushes `main`, creates the `vX.Y.Z` GitHub release. The `release.yml` workflow then tests, builds, Sigstore-signs, and trusted-publishes to RubyGems (environment `rubygems`).

`bin/release`, `rakelib/release.rake` and the shared jobs of `release.yml` are byte-identical across the zoolutions gems (docs-kit, daisyui, dash, pgbus, phlex-reactive): change them in every repo or none. dash-only release steps live in the `release:preflight` / `release:prepare` hooks in the `Rakefile`.

Gem tags are plain `vX.Y.Z` (own semver, 3.x line). Historical `dash-v*` tags are frozen. Proxy tags stay `v<base>.<n>` (or plain semver).

## Labels

Every pull request carries exactly one `type` label and at least one `area`
label from `.github/labels.yml` — never a `status` label. `/flow:plan` labels the
issue, `/flow:lfg` copies the issue's `type` and `area` labels onto the PR (never
`plan` or another status label). Without an issue, the type comes from the
change's conventional-commit prefix and the areas from
`bin/labels infer $(git diff --name-only origin/main...HEAD)`. Labels change in
the manifest and reach GitHub with `bin/labels sync`, never through the UI.
Rules: `.github/LABELS.md`. `bin/labels` + `.github/LABELS.md` are the shared
labels kit (canonical copy in docs-kit): never edit them in place.

## Proxy image contract

- dash reads the running proxy version FROM THE IMAGE TAG (`docker inspect kamal-proxy --format '{{.Config.Image}}'`) and compares it with `Gem::Version` (`Dash::Utils.older_version?`). Only the tag is compared, so old `kamal-proxy`-image containers upgrade cleanly to `dash-proxy` images.
- The image must carry the label `org.opencontainers.image.title=kamal-proxy` — `dash proxy remove` prunes by it (label rename waits for the bridge).
- Defaults live in `lib/dash/configuration/proxy/run.rb` (`MINIMUM_VERSION`, repository `ghcr.io/zoolutions/dash-proxy`) and `lib/dash/configuration/proxy/boot.rb` (legacy boot path).
- The old `ghcr.io/zoolutions/kamal-proxy` package stays published — gem versions < 3.2.0 pull it.

## Staged rename (issue #115 stages 2–3)

| Stage | Scope | Status |
|---|---|---|
| 1 | CLI executable + user-facing text + docs (`dash` only) | DONE (3.2.0) |
| 2 | Ruby namespace `Kamal::` → `Dash::`, `lib/kamal` → `lib/dash` | DONE (#117) |
| 3a | Local project directory `.kamal/` → `.dash/`, dual-emitted `DASH_*`/`KAMAL_*` env vars | DONE (#125) |
| 3b | Server run directory `.kamal/` → `.dash/` (self-migrating `mv`), config-digest label `org.kamal.*` → `org.dash.*` (read-both), local registry container | DONE (#123) |
| 3c | `kamal-proxy` container + network + volume names, `org.opencontainers.image.title` — needs a coordinated dash-proxy release | follow-up issue |
| 3d | Drop the read-both fallbacks (`.kamal/` project dir, legacy digest label) | 5.0 |

## Testing

- Unit: everything under `test/` except `test/integration` — genuinely no Docker needed. `test_helper.rb` pins `Dash::Utils.docker_arch` and stubs `Dash::Docker.included_files`, so the suite is green whether or not a daemon is running. The old "two builder tests fail on Apple Silicon" caveat is gone — they were reading the local daemon's architecture.
- Integration: real deploys against Docker-in-Docker VMs; pulls `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION` — the tag must be published or the suite fails.
- CI: rubocop + actionlint/zizmor + Ruby 3.2–4.0 matrix on `main`.
- Multi-host fixtures with a >1-host primary role need `loadbalancer: false` under `proxy:` — the loadbalancer auto-activates and the dind harness can't support it.

## Workflow

- **Verify:** `bundle exec rubocop --parallel` · `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'` (unit, no Docker) · `bin/test` before merging when deploy/proxy/boot paths changed (Docker + the published proxy image at `MINIMUM_VERSION`)
- **Specs:** fast loop `bundle exec ruby -Itest <test file>`; full suite `bin/test`; two worktrees at once: unit yes, integration one at a time (shared Docker daemon)
- **CI:** required `Tests (Ruby 3.2)`, `3.3`, `3.4`, `4.0`, `cubic · AI code reviewer` (branch must be up to date); `RuboCop` and `GitHub Actions audit` report only; `Docs site / Build & test` on `docs/**` only; full suite on the PR; failure report none
- **Review bot:** cubic
- **Merge:** squash — `gh pr merge <PR> --squash --delete-branch`; fallback after the gate: `--admin` for the ruleset's one-approval rule
- **PR contract:** `## Summary`, `## Test plan`; exactly one `type` + at least one `area` label (`## Labels`); plain Markdown body, backticks never escaped, `--body-file` for long ones
- **Conflicts:** merge `main` forward, never rebase; `lib/dash/version.rb` — main's (only `rake release` writes it); `Gemfile.lock` `docs/Gemfile.lock` — either side, then `bundle install`, never hand-merged; `dash.gemspec` — keep both sides' dependencies; `lib/dash/configuration/proxy/run.rb` — keep the `ghcr.io/zoolutions` repository, a `MINIMUM_VERSION` conflict is a release-ordering question (flag it); `test/{cli,commands}/proxy_test.rb` — keep the ghcr org and the `MINIMUM_VERSION` interpolation; `test/integration/docker/deployer/setup.sh` — literal tag equal to `MINIMUM_VERSION`; `git rerere` is on, `git diff --staged` before trusting a replay
- **Worktree setup:** `bundle install`; undo none
- **Release:** `bin/release <v>` (proxy image first, see Release flow); changelog none (release notes under `docs/release-notes/`); prep none; lockfiles `Gemfile.lock` `docs/Gemfile.lock`; docs `deploy-docs.yml` on release; human none
- **Main health:** `gh run list --workflow ci.yml --branch main --event push --limit 1 --json conclusion,headSha`
- **Upstream:** libraries we own `zoolutions/*` (the proxy is `zoolutions/dash-proxy`); scrub none
- **Bench:** none (the gem has no bench suite and none is invented: reason about loop and SSH call counts; the proxy's is `make bench` in `../kamal-proxy`)

## Agent commands

Plugins (`.claude/settings.json`): `/flow:lfg`, `/flow:plan`, `/flow:follow-through`, `/flow:finish-prs`,
`/flow:github-review-pr` (`-failures`, `-comments`), `/flow:review-pr`, `/flow:tdd`, `/flow:debug-flaky`,
the `flow:fable-validator` agent; `/ruby-gem:release`, `/ruby-gem:perf`. Local (`.claude/commands/`):
`/architect` (Thor CLI → Commander → Commands → Configuration across the gem and `../kamal-proxy`),
`/security` (SSH command construction, secrets, shell escaping, error-page paths).

**Models.** Sessions run on `opus` with `fable` as the advisor (`.claude/settings.json`); consult it
before choosing an approach, a public API, a dependency, anything irreversible, and when a failure
repeats. Every spawned agent names its `model:`; one that does not runs on `sonnet`
(`CLAUDE_CODE_SUBAGENT_MODEL`), never on the session's model. A new Thor command or config option goes
through a Plan agent first (it touches `Cli`, `Configuration` and `test/` together); a proxy-version
change is cross-repo, so sequence `../kamal-proxy` first.

## Code rules

- Keep the layers apart: `Cli` parses options and orchestrates `on()`/`modify()`; `Commands` builds argv arrays (pure, no SSH; `argumentize`/`optionize`, never hand-built shell strings); `Configuration` turns `deploy.yml` into objects.
- Rescue the specific `SSHKit::Command::Failed` / Docker error and re-raise the rest, never `StandardError` → nil. No shared mutable state inside `on()` blocks.
- New proxy-image code uses `ghcr.io/zoolutions/dash-proxy` (`Proxy::Run#repository`, `Proxy::Boot#repository_name`), not `basecamp/kamal-proxy`. Loadbalancer-only code (`Cli::Proxy#loadbalancer`, `DASH.loadbalancer`, `Configuration::Proxy#load_balancing?`) stays behind `load_balancing?` checks.
- Tests: Minitest + Mocha (`any_instance.stubs`), no RSpec; `SSHKit::Backend::Printer` prints instead of executing, assert the printed command; no real SSH, network or secrets in unit tests (fixtures under `test/fixtures/`). 100% coverage for `Proxy::Run`, `Commander`, `Configuration`, `Commands::Proxy`/loadbalancer activation and `Cli::Main` hooks.
- A unit test that varies by host is new reach outside the process (Docker, network, clock): fix that, don't add a known-failures list.
- `bin/labels` and `.github/LABELS.md` are the shared labels kit (canonical copy in docs-kit, `script/labels-kit sync`): never edit them here.
- Performance claims need a same-machine before/after from `main` in a worktree; otherwise say "measured after only".

## More Documentation

- `docs/` — the documentation site: a self-contained docs-kit Rails app (own bundle, RSpec, CI job `docs-ci.yml`), deployed to https://dash.zoolutions.llc by `deploy-docs.yml` on each release. The Configuration pages are GENERATED from `lib/dash/configuration/docs/*.yml` (parsed by `docs/app/models/config_doc.rb`); a new doc YAML fails `docs/spec/config_docs_spec.rb` until registered in `docs/app/models/doc.rb`.
- `ROADMAP.md` — evidence-linked improvement roadmap
- `.claude/commands/` — the local commands above
- Proxy repo: `../kamal-proxy/CLAUDE.md` — cross-repo release ordering
- Upstream kamal docs (shared basics): https://kamal-deploy.org
