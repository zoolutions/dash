---
description: Review a GitHub pull request for code quality, patterns, and fork constraints
model: opus
argument-hint: "PR URL or number (e.g., 42 or https://github.com/mhenrixon/kamal/pull/42)"
allowed-tools: mcp__github__pull_request_read, mcp__github__pull_request_review_write, mcp__github__get_file_contents, Bash(bundle exec rubocop:*), Bash(bin/test:*), Bash(bundle exec ruby -Itest:*), Bash(git diff:*), Bash(git log:*), Read, Grep, Glob
---

# PR Review

Review PR for pattern compliance, fork-constraint violations, and issues. Be concise.

## Workflow

1. Fetch PR details and diff via `mcp__github__pull_request_read` (repo: `mhenrixon/kamal`)
2. Identify target branch — `main` or `dash`? (see Fork Constraints below)
3. Categorize changed files by layer (see CLAUDE.md architecture)
4. Check for pattern violations and fork-constraint violations
5. Run `bundle exec rubocop --parallel` and unit tests locally against the PR diff if feasible
6. Output structured review

## Fork Constraints (check first — these block merge regardless of code quality)

| Check | Violation | Why it matters |
|---|---|---|
| Base branch | PR targets `main` | `main` is a fast-forward-only mirror of upstream — nothing merges there except upstream syncs |
| Upstream-owned files touched | Edits to `kamal.gemspec`, `bin/release` | Fork keeps these byte-identical to upstream so syncs never conflict; fork owns `dash.gemspec` / `bin/release-dash` |
| Tag grammar (if PR touches release scripts/docs) | Plain `v2.x.y` gem tags | Upstream owns bare `v*`; fork gem tags are `dash-v<version>` (four-segment, e.g. `2.12.0.1`) |
| `git push --tags` in any script/workflow | Pushes fetched upstream tags into the fork | Always push single tags: `git push origin tag dash-v2.12.0.1` |
| Proxy version literals | Hardcoded `"v0.9.2.1"` (or similar) in tests/specs instead of interpolating `MINIMUM_VERSION` | `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` is the single source of truth |
| Proxy version suffix | `-dash.N` style suffix on a proxy tag | `Gem::Version` parses `-` as a prerelease, sorts OLDER than base, breaks `kamal proxy boot` |
| Release ordering | Gem release/version bump referencing an unpublished proxy tag | Proxy image must exist on ghcr.io BEFORE the gem release that names it in `MINIMUM_VERSION` |
| Rebase of `main` or `dash` | Force-push / rebase on a published branch | History is shared; merge forward only, never rebase |
| New multi-host integration fixture without `loadbalancer: false` | Loadbalancer auto-activates for >1 web host under `proxy:` role | Breaks the dind integration harness (inner docker network can't resolve vm hostnames) |

## Pattern Violations to Check

```ruby
# WRONG -> RIGHT
Business logic in Cli::* Thor command       -> Push logic down into Commander/Commands/Configuration
Direct shell interpolation in Commands::*    -> Build args as arrays, let SSHKit/Docker quote them
Raw ENV reads scattered in Configuration     -> Route through Kamal::Configuration::Env / config accessors
Hardcoded proxy image tag                    -> Kamal::Configuration::Proxy::Run::MINIMUM_VERSION
Hardcoded ghcr.io/zoolutions repo string       -> Proxy::Run#repository default / config override
New CLI option without Thor `desc`/`option`  -> Follow existing Cli::* option declarations
Missing `--parallel`-unsafe rubocop offense  -> Run `bundle exec rubocop --parallel` clean
Test hits Docker/network without being under -> Belongs in test/integration, not test/ (unit run
  test/integration                              excludes integration via grep_v)
rescue => nil / swallowed SSHKit errors      -> Surface via existing error classes (Kamal::Cli::Base rescues)
Duplicated logic across Cli/Commands/Config  -> Push to the correct single layer (see architecture)
```

## Architecture Sanity Check

Match each changed file to its layer — logic living at the wrong layer is the most common review finding:

```
Layer 5: bin/kamal, bin/dash       entry points only
Layer 4: lib/kamal/cli/*           Thor commands, option parsing, hooks — thin
Layer 3: lib/kamal/commander.rb    KAMAL singleton, target resolution
Layer 2: lib/kamal/commands/*      docker/shell command builders (return argv arrays)
Layer 1: lib/kamal/configuration/* deploy.yml -> objects, validation, defaults
Layer 0: SSHKit                    remote execution (don't hand-roll ssh/scp)
```

## Test & Lint Verification

```bash
bundle exec rubocop --parallel
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
bin/test   # full suite incl. integration — needs Docker + published proxy image; only if PR touches proxy/deploy paths
```

Two builder tests are known-failing on Apple Silicon only (host-arch dependent) — do not flag them as PR-introduced regressions; confirm against `main` first if unsure.

## Output Format

```
## Files Requiring Manual Review

| File | Reason |
|------|--------|
| lib/kamal/commands/proxy.rb | Docker arg construction, verify shell-safety |
| lib/kamal/configuration/proxy/run.rb | MINIMUM_VERSION / repository default touched |

## Fork Constraint Violations

- Targets `main` instead of `dash`
- `test/commands/proxy_test.rb:30` hardcodes `"v0.9.2.1"` instead of interpolating `MINIMUM_VERSION`

## Critical Issues

- `lib/kamal/cli/proxy.rb:45` - Business logic belongs in Commander, not the Thor command
- `lib/kamal/commands/app.rb:12` - Shell interpolation instead of argv array

## Suggestions (non-blocking)

- Consider extracting X to a shared Configuration object

## Verdict

**Request Changes** - Retarget to `dash`; fix MINIMUM_VERSION hardcoding before merge
```

## Tools

```
mcp__github__pull_request_read
  method: "get"        -> PR details (confirm base ref == "dash")
  method: "get_diff"   -> Changes
  method: "get_files"  -> File list
  method: "get_status" -> CI status

bundle exec rubocop --parallel   -> Style checks
bin/test                         -> Full suite (Docker + proxy image required)
```

## Cross-References

- `CLAUDE.md` — Critical Rules, architecture layers, fork identity table
- `.claude/rules/upstream-sync.md` — branch roles, conflict playbook, release ordering
- `ROADMAP.md` — whether this PR maps to a planned release item
