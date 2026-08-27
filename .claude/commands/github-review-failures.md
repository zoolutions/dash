---
description: "Use when CI checks are failing on a PR — fetches failure logs, diagnoses root causes, implements fixes, and pushes until CI is green."
model: sonnet
argument-hint: "PR number (e.g., 41 or #41)"
allowed-tools: Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr diff:*), Bash(gh api:*), Bash(gh run view:*), Bash(git log:*), Bash(git diff:*), Bash(git push:*), Bash(git commit:*), Bash(git add:*), Bash(bin/test:*), Bash(bundle exec:*), Read, Write, Edit, Glob, Grep, Agent
---

# Fix GitHub CI Failures: $ARGUMENTS

You are diagnosing and fixing CI failures on a `dash` (kamal fork) pull request. Work systematically: identify failures, read logs, diagnose root causes, fix locally, verify, push.

Which repo is this? This command runs in whichever of the two fork repos the PR belongs to — the gem at `zoolutions/dash` (Ruby) or the proxy at `zoolutions/dash-proxy` (Go). Detect it from `git remote get-url origin` before proceeding; Phase 1's check table branches on it.

## Phase 0: Determine the PR Number

The user may provide a PR number as `$ARGUMENTS`. Parse it flexibly:

- `PR41`, `PR 41`, `pr41` -> PR 41
- `41` -> PR 41
- `#41` -> PR 41
- Empty/blank -> auto-detect from current branch

**If no PR number is provided**, detect it automatically:

```bash
gh pr list --author=@me --head="$(git branch --show-current)" --state=open --json number,title
```

If exactly one open PR exists for the current branch, use it. If none or multiple, ask the user.

Once you have the PR number, confirm it and its base branch:

```bash
gh pr view <PR_NUMBER> --json title,state,url,baseRefName,mergeable
```

**PRs target `dash`, never `main`.** If `baseRefName` is `main`, stop and flag it — see `.claude/rules/upstream-sync.md`.

**Pre-flight: merge conflicts (detection only).** If `mergeable` is `CONFLICTING`, STOP — do not diagnose CI on a conflicted branch (the merge itself may fix or cause the failures). Report the conflict and hand off to `/github-review-pr`, whose Phase A0 owns the resolution runbook — this command's toolset deliberately does not include the merge machinery. If `mergeable` is `UNKNOWN`, note it and proceed: the orchestrator resolves the ambiguity; a standalone run shouldn't block on GitHub's recompute.

---

## Phase 1: Identify Failing Checks

```bash
gh pr checks <PR_NUMBER>
```

Categorise each failing check:

| Repo | Check | What it runs | How to get logs |
|---|---|---|---|
| gem (kamal) | `RuboCop` | `bundle exec rubocop --parallel` | `gh run view <RUN_ID> --job=<JOB_ID> --log-failed` |
| gem (kamal) | `GitHub Actions audit` | actionlint + zizmor on `.github/workflows/*` | `gh run view <RUN_ID> --job=<JOB_ID> --log-failed` |
| gem (kamal) | `Tests (Ruby 3.2\|3.3\|3.4\|4.0)` × `Gemfile`/`gemfiles/rails_edge.gemfile` | `bin/test` (full suite, incl. integration, inside CI's Docker) | `gh run view <RUN_ID> --job=<JOB_ID> --log-failed` |
| proxy (kamal-proxy) | `lint-actions` | actionlint + zizmor | `gh run view <RUN_ID> --job=<JOB_ID> --log-failed` |
| proxy (kamal-proxy) | `build` | `make build && make test && make lint` (golangci-lint) | `gh run view <RUN_ID> --job=<JOB_ID> --log-failed` |

Extract the run ID and job IDs from the check URLs. The URL format is:
`https://github.com/mhenrixon/<repo>/actions/runs/<RUN_ID>/job/<JOB_ID>`

If all checks pass or are pending, report that and stop.

---

## Phase 2: Fetch Failure Logs

For each failing check, get the logs:

```bash
# Get the failed job logs (condensed output)
gh run view <RUN_ID> --job=<JOB_ID> --log-failed
```

If `--log-failed` output is too large or unclear, try:

```bash
# Full log for a specific job
gh run view <RUN_ID> --job=<JOB_ID> --log 2>&1 | tail -100
```

---

## Phase 3: Diagnose Each Failure

For each failure, determine the root cause.

### RuboCop failures (gem)

Look for: file path, line number, cop name, message. **Key**: most are auto-fixable with `bundle exec rubocop -A <file>` — verify the autocorrect didn't change behavior before committing it.

### Test failures (gem — Minitest + Mocha, NOT RSpec)

Look for:
- Test name and file path (`test/**/*_test.rb`)
- Error class and message
- Relevant backtrace lines (ignore SSHKit/Thor framework noise)
- Whether it's an environment issue vs an actual code bug

**Key patterns**:
- `NameError: uninitialized constant` -> missing require or Zeitwerk autoload mismatch
- `NoMethodError: undefined method` -> API change in `Dash::Commands`/`Dash::Configuration`
- `Mocha::ExpectationError` -> mock/stub no longer matches the call site
- `expected: X, got: Y` on a proxy version string -> check whether the test hardcoded a proxy tag instead of interpolating `Dash::Configuration::Proxy::Run::MINIMUM_VERSION`
- Integration test failure pulling `ghcr.io/zoolutions/kamal-proxy:<tag>` -> the tag isn't published yet (see Known/Expected Failures below), not a code bug

### golangci-lint / go test failures (proxy)

Look for: `make lint` offenses (vet, staticcheck-style findings) and `make test` failures under `internal/`. Fix root cause; don't add `//nolint` to silence a real issue.

### GitHub Actions audit failures (both repos)

`actionlint` catches workflow YAML/expression errors; `zizmor` catches workflow security issues (unpinned actions, script injection via `${{ }}` in `run:`). Both repos pin actions to a commit SHA with a version comment — match that style when editing a workflow.

---

## Phase 4: Fix Locally

For each diagnosed failure:

1. **Read the relevant file** to understand context before fixing.
2. **Make the fix** — edit the file.
3. **Verify locally** before committing:

```bash
# gem: rubocop
bundle exec rubocop --parallel

# gem: unit tests only (fast, no Docker)
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'

# gem: full suite incl. integration (needs Docker + the published proxy image)
bin/test

# proxy: full local CI equivalent
make build && make test && make lint
```

### Fix Priority Order

1. **Lint/style fixes** first (fast, deterministic) — `rubocop -A`, `golangci-lint run --fix`
2. **Unit test failures** second (may require understanding the code change)
3. **Integration/build issues** third — check Known/Expected Failures before spending time on these

---

## Phase 5: Commit and Push

```bash
git add <specific_files>
git commit -m "$(cat <<'EOF'
fix(ci): <brief description of what was fixed>

- Fix 1 description
- Fix 2 description
EOF
)"
git push
```

`dash.gemspec` is the only gemspec since the 2026-08 clean break — edit it directly for dependency-related failures.

---

## Phase 6: Verify

After pushing, check if CI has been re-triggered:

```bash
gh pr checks <PR_NUMBER>
```

If there are still pending checks, report which checks are running and what was fixed. Do NOT poll in a loop — report the status and let the user know.

---

## Known/Expected Failures — do not "fix" these

| Failure | Cause | Action |
|---|---|---|
| A test passes locally but fails in CI (or vice versa) | Look for a call that reaches outside the process — Docker, the network, the clock. `test_helper.rb` pins the two that used to do this |
| Integration suite fails pulling `ghcr.io/zoolutions/kamal-proxy:<MINIMUM_VERSION>` | Tag not yet published to ghcr.io, or `MINIMUM_VERSION` was bumped without a matching proxy release | Check `docker buildx imagetools inspect ghcr.io/zoolutions/kamal-proxy:<tag>`; if unpublished, this is a release-ordering issue, not a code bug — see `.claude/rules/upstream-sync.md` |
| Any check failing on a PR whose base is `main` | `main` must stay a pristine fast-forward mirror of upstream | Flag it; the PR should retarget `dash` |

---

## Important Notes

- **Read before fixing** — always read the actual failing code before attempting a fix
- **Fix the root cause** — don't add `# rubocop:disable` or `//nolint` to bypass lint; fix the actual issue
- **Don't fix unrelated failures** — if a test was already failing on `dash` before this PR, note it but don't fix it here
- **Never rename frozen server artifacts** to chase a fix — `.kamal/`, the `kamal-proxy` container, `KAMAL_*` env vars, and the image title label wait for the staged rename bridge (CLAUDE.md); if a fix seems to require touching one, the real fix is elsewhere
- **Flaky vs environmental** — a test that passes locally but fails in CI (or vice versa) may be one of the Known/Expected Failures above; check that table first
- **Genuinely intermittent failures** — if a failure looks flaky (passed on re-run, fails only sometimes, only one matrix cell), hand off to `/debug-flaky` instead of adding workarounds; it owns the reproduction ladder and the knowledge base (`docs/flaky-tests.md`)
- **Don't retry CI blindly** — diagnose first, fix, then push. Each push triggers a full CI run (and the gem matrix alone is 4 Ruby versions × 2 Gemfiles)

Now begin by detecting the repo, determining the PR number, and fetching the failing checks.
