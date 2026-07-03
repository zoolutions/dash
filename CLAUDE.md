# dash

mhenrixon's maintained fork of [kamal](https://github.com/basecamp/kamal) — deploy web apps anywhere, plus the features upstream won't merge (proxy load balancing). Published on rubygems.org as `dash`; the executable is still `kamal` (with `dash` as an alias) and the Ruby namespace is still `Kamal::`.

## Tech Stack

- **Ruby**: 3.2–4.0 (CI matrix), Thor CLI, SSHKit + net-ssh, Zeitwerk
- **Gem**: `dash`, built from `dash.gemspec` (`kamal.gemspec` is upstream's — untouched)
- **Proxy**: ghcr.io/mhenrixon/kamal-proxy (fork of basecamp/kamal-proxy, sibling repo)
- **Testing**: minitest + mocha; integration tests run real deploys in Docker
- **Linting**: rubocop-rails-omakase

## Critical Rules

### Never Do

1. **NO commits on `main`** — it is a fast-forward-only mirror of basecamp/kamal
2. **NO edits to `kamal.gemspec` or `bin/release`** — upstream files kept pristine so syncs never conflict; the fork owns `dash.gemspec` and `bin/release-dash`
3. **NO `v*` git tags** — upstream owns that namespace; fork gem tags are `dash-v<version>`
4. **NO `git push --tags`** — it would push fetched upstream tags to the fork; push single tags (`git push origin tag dash-v2.12.0.1`)
5. **NO suffix proxy versions** like `v0.9.2-dash.1` — Gem::Version parses `-` as a prerelease, which sorts OLDER than the base and hard-fails `kamal proxy boot`
6. **NO gem release before the proxy image exists** — the tag named by `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` must be pullable from ghcr.io first
7. **NO rebasing published branches** — merge `main` forward; history is shared

### Always Do

1. **Branch features off `main`** — keeps them upstream-PR-able; merge them into `dash`
2. **Mirror `kamal.gemspec` dependency changes into `dash.gemspec`** after every sync (`diff kamal.gemspec dash.gemspec`)
3. **Interpolate `MINIMUM_VERSION` in test expectations** — never hardcode proxy versions
4. **Run unit tests + rubocop before pushing `dash`**

## Commands

```bash
bin/test                              # Full suite (integration needs Docker + published proxy image)
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests only
bundle exec rubocop --parallel        # Lint
bin/release-dash 2.12.0.1             # Release the dash gem (proxy image must exist first)
git fetch upstream --tags --prune     # Start of every sync
```

## Architecture

```
Layer 5: bin/kamal, bin/dash       (identical entry points -> Kamal::Cli::Main)
Layer 4: Kamal::Cli::*             lib/kamal/cli (Thor commands, hooks)
Layer 3: Kamal::Commander          lib/kamal/commander.rb (KAMAL singleton, target resolution)
Layer 2: Kamal::Commands::*        lib/kamal/commands (docker command builders)
Layer 1: Kamal::Configuration      lib/kamal/configuration (deploy.yml -> objects, validation)
Layer 0: SSHKit                    (remote execution)
```

## The mental model

> `main` is basecamp's; `dash` is ours. A dash release is the `dash` branch plus a published proxy image whose tag equals `MINIMUM_VERSION`. Everything the fork changes fits in ~10 files — everything else must stay byte-identical to upstream.

## Fork identity (divergence from upstream)

| File | Change |
|---|---|
| `dash.gemspec`, `bin/dash`, `bin/release-dash` | fork-owned new files |
| `Gemfile`, `gemfiles/rails_edge.gemfile` | `gemspec name: "dash"` (bare `gemspec` errors with two gemspecs) |
| `lib/kamal/configuration/proxy/run.rb` | `MINIMUM_VERSION` = fork tag; default repository `ghcr.io/mhenrixon/kamal-proxy` |
| `lib/kamal/configuration/proxy/boot.rb` | `repository_name` = `ghcr.io/mhenrixon` (legacy boot path) |
| `lib/kamal/configuration/docs/proxy.yml` | documented default |
| `test/**` | proxy image org + `#{MINIMUM_VERSION}` interpolation; integration `setup.sh` seeds the ghcr image |
| `.github/workflows/*` | CI on `dash`; CLI image -> ghcr.io/mhenrixon/dash |

Features (loadbalancing, …) live on their own branches and merge into `dash` — see `.claude/rules/upstream-sync.md`.

## Proxy image contract

- kamal reads the running proxy version FROM THE IMAGE TAG (`docker inspect kamal-proxy --format '{{.Config.Image}}'`) and compares it with `Gem::Version` (`Kamal::Utils.older_version?`).
- Fork tags are four-segment `v<upstream-base>.<counter>` (e.g. `v0.9.2.1`): sorts above the base, below the next upstream release, never collides with upstream git tags.
- The image must carry the label `org.opencontainers.image.title=kamal-proxy` — `kamal proxy remove` prunes by it.

## Testing

- Unit: everything under `test/` except `test/integration` — no Docker needed. Two builder tests fail on Apple Silicon (host-arch dependent; they pass in CI and on pristine main).
- Integration: real deploys against Docker-in-Docker VMs; pulls `ghcr.io/mhenrixon/kamal-proxy:$MINIMUM_VERSION` — the tag must be published or the suite fails.
- CI: rubocop + actionlint/zizmor + Ruby 3.2–4.0 matrix, on `main` and `dash` pushes.

## More Documentation

- `.claude/rules/upstream-sync.md` — sync runbook, conflict playbook, release procedure
- Proxy fork: `../kamal-proxy/CLAUDE.md` — cross-repo release ordering
- Upstream docs: https://kamal-deploy.org
