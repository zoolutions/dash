# Git Workflow Rules

Fork-specific. See `CLAUDE.md` for architecture/tooling and `.claude/rules/upstream-sync.md` for the sync/release runbook — this file does not duplicate either.

## Branch Model

| Branch | Role | Rule |
|---|---|---|
| `main` | Mirror of `basecamp/kamal` | Fast-forward only — **NEVER** commit here |
| `dash` | Integration + release branch | Fork identity + merged features; PRs target this |
| `feat/*` | Feature branches | Root off `dash` (always), merge **forward** into `dash` |

**ALWAYS** root a feature branch off `dash`, never off `main`. `dash` is where the fork's features, fixes and toolkit live, so a `dash`-rooted branch builds on the real codebase, gets the `.claude/` toolkit for free, and merges back without replaying fork identity. Upstreaming stays possible from a `dash`-rooted branch — see "Upstreaming a feature" in `.claude/rules/upstream-sync.md` — it just extracts the feature's own diff instead of relying on the branch point.

**NEVER** rebase a published branch (`main`, `dash`, or a shared `feat/*`) — history is shared, merge forward instead.

## Commit Messages

Conventional commits:
- `feat:` — new feature
- `fix:` — bug fix
- `refactor:` — code refactoring
- `perf:` — performance improvement
- `docs:` — documentation only
- `test:` — adding/updating tests
- `chore:` — maintenance tasks
- `ci:` — CI/CD changes

Format:
```
feat(scope): brief description

Longer explanation if needed. Focus on WHY, not WHAT.

Refs #123
```

## Branch Naming

- `feat/description` — new features (e.g. `feat/loadbalancing`)
- `fix/description` — bug fixes
- `refactor/description` — refactoring
- `ci/description` — CI changes
- `chore/description` — maintenance

## PR Workflow

1. Branch off `dash`, never off `main`
2. Make focused, atomic commits
3. Run the pre-commit checklist before every push
4. Open the PR against `dash` (never `main`)
5. Request review
6. Merge `dash` → your feature branch whenever `dash` moves, then merge the branch back into `dash` — never rebase

## PR and Issue Bodies

Write PR/issue bodies in plain Markdown. **Do not escape backticks** with `\`` — GitHub renders `\`` literally as a backslash followed by a backtick, producing `` \`Kamal::Commander\` `` instead of the monospace `Kamal::Commander` the reader expects.

The usual cause is writing the body inside a bash heredoc (`gh pr create --body "$(cat <<'EOF' ... EOF)"`) and reflexively escaping every backtick out of shell-quoting muscle memory. With `<<'EOF'` (single-quoted delimiter) the shell does NOT interpret anything inside the heredoc — backticks, dollars, and backslashes all pass through verbatim. Write them exactly as you want them rendered. If you find yourself typing `\`` inside a PR body, stop and remove the backslash.

For long bodies or many code fences, prefer `--body-file <tmpfile>` — it skips shell interpretation entirely.

## Pre-Commit Checklist

Run before EVERY commit:
```bash
bundle exec rubocop --parallel        # Style
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests (no Docker)
```

Before pushing `dash` or opening a PR into it, run the full suite (needs Docker + the proxy image published at `MINIMUM_VERSION`):
```bash
bin/test
```

Two builder tests are known-failing on Apple Silicon only (host-arch dependent) — they pass in CI. Don't chase them locally.

## Tags — Never Plain `v*`

| What | Grammar | Example | Push |
|---|---|---|---|
| Gem (this repo) | `dash-v<semver>` (own major from 3.0.0) | `dash-v3.0.0` | `git push origin tag dash-v3.0.0` |
| Proxy image (kamal-proxy) | `v<upstream-base>.<n>` | `v0.9.2.1` | `git push origin tag v0.9.2.1` |

- **NEVER** a bare `v<version>` tag — upstream owns that namespace on both repos
- **NEVER** `-suffix` versions (e.g. `v0.9.2-dash.1`) — `Gem::Version` parses `-` as a prerelease, sorts it BELOW the base, and breaks `kamal proxy boot`'s version check
- **NEVER** `git push --tags` — it would push fetched upstream tags into the fork's remote; push one tag at a time

## Release Ordering — Hard Constraint

**Proxy image before gem, always.** `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` must name a tag already published at `ghcr.io/zoolutions/kamal-proxy` before `bin/release-dash` runs — integration tests and `kamal proxy boot` pull it.

```bash
# 1. ../kamal-proxy, on dash
script/release-dash v0.9.2.1

# 2. this repo, on dash — confirm MINIMUM_VERSION matches, then:
bin/test
bin/release-dash 3.0.0
```

Full procedure, conflict playbook, and sync runbook: `.claude/rules/upstream-sync.md`.

## Rules

- **NEVER** commit directly to `main`
- **NEVER** root a feature branch off `main` — always off `dash`
- **NEVER** force push to `main` or `dash`
- **NEVER** edit `kamal.gemspec` or `bin/release` — upstream-owned, kept byte-identical so syncs never conflict
- **ALWAYS** run rubocop + unit tests before pushing; run `bin/test` before merging into `dash`
- **ALWAYS** write meaningful commit messages — explain WHY
- Keep commits small and focused, one logical change per commit
