---
description: "Use when a CI test failure looks intermittent — takes a failed Actions run, PR, or test path; drives evidence → reproduction → root cause → stress-proofed fix → knowledge capture. Never masks with skip/retry."
model: opus
argument-hint: "Actions run URL/ID, PR number, or test path (e.g. test/integration/app_test.rb)"
allowed-tools: Bash(gh run view:*), Bash(gh run download:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh api:*), Bash(gh issue list:*), Bash(gh issue view:*), Bash(gh issue create:*), Bash(gh issue edit:*), Bash(gh label list:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git blame:*), Bash(bin/test:*), Bash(bundle exec:*), Bash(docker:*), Read, Write, Edit, Glob, Grep, Agent
---

# Debug Flaky Test: $ARGUMENTS

You are root-causing an intermittent test failure. The deliverable is the **mechanism, stated in one sentence**, then a fix proven by a stress gate — never a `skip`, a retry wrapper, a `sleep`, or a loosened assertion.

## Phase 0: Parse the input

- **Actions run URL/ID** (`https://github.com/zoolutions/dash/actions/runs/<RUN_ID>` or a bare run id) → start at Phase 1.
- **PR number** → `gh pr checks <N>` to find the failed run, then Phase 1.
- **Test path** (a locally observed flake) → skip to Phase 2 with what the user told you.

## Phase 1: Extract the CI evidence

```bash
gh run view <RUN_ID> --json jobs --jq '.jobs[] | {name, conclusion, databaseId}'
gh run view <RUN_ID> --job <JOB_ID> --log-failed
```

From the failing job's full log (`--log` if `--log-failed` is too thin), extract ALL of:

| Evidence | Where in the log | Why it matters |
|----------|------------------|----------------|
| Failed test names + files | `Failure:` / `Error:` blocks | The targets |
| Minitest seed | `Run options: --seed N` | Exact-order reproduction |
| Which matrix cell failed | Job name: `Tests (Ruby 3.2\|3.3\|3.4\|4.0)` × `Gemfile`/`rails_edge` | Ruby/Rails-version dependence vs true flake |
| Docker/compose noise before the failure | `docker compose` / image pull / health-check lines | Integration-harness flakiness vs test-logic flakiness |
| Branch/SHA of the run | `gh run view <RUN_ID> --json headBranch,headSha` | What code actually ran |

**Read the matrix:** the same test failing in ALL cells is likely deterministic (a regression, not a flake). Failing in ONE cell only → version-dependent or a genuinely intermittent race that happened to hit once.

## Phase 2: Consult the knowledge base

1. Read `docs/flaky-tests.md` if it exists — if the test (or its pattern) has an entry, start from the recorded recipe.
2. `git log --oneline --grep="flak" --grep="orphan" --grep="race" -i -20` — this repo (and upstream) has a history of flake-hardening commits (SSHKit eviction-thread kills, storage-driver switches, compose retry logic). The mechanism you're chasing may have precedent.
3. `gh issue list --repo zoolutions/dash --label flaky-test --state all --search "<test filename>"` — check for open/closed history.
4. If a matching open issue exists, work under it; otherwise you'll create one in Phase 8 only if the fix doesn't ship immediately.

## Phase 3: Is it actually flaky? (do this BEFORE any flake taxonomy)

"Intermittent across builds" is compatible with "deterministic on any given commit". Checks, in order:

1. **Run the failing test on the run's branch**: `bin/test <file>` (repeat 3×). If it fails every time, this is a **regression, not a flake** — find the commit pair whose interaction broke it: `git log` the test file AND the code it exercises; look for an upstream sync (`git merge main`) that landed between the last green and first red.
2. **Rule out a stale environment assumption.** The suite used to track whether Docker was running: `Dash::Utils.docker_arch` shelled out to `docker info`, and `Dash::Docker.included_files` ran a real build. Both are pinned in `test_helper.rb` now. If a test starts varying again, look first for a new call that reaches outside the process.
3. **Check the matrix cell.** A failure only on `rails_edge` or only on Ruby 4.0 is a compatibility break, not a flake — fix it as a regression against that version.

## Phase 4: Classify the signature

| Class | Tell | Reproduction strategy |
|-------|------|----------------------|
| Order / state leakage | passes alone, fails after certain files | `--seed N` re-run; suspects: ENV mutation without teardown (`ENV["VERSION"]`, `ENV["KAMAL_*"]`), the `KAMAL` commander singleton, SSHKit global config/pool |
| Thread / process leakage | errors in teardown, `Mocha::NotInitializedError`, stuck PTY | leftover background threads (SSHKit eviction thread — see `test_helper.rb`'s kill logic), unkilled PTY children |
| Time-dependence | failures cluster at boundaries (timeouts, drain intervals) | re-run around the boundary; look for real `sleep`/timeout maths in the test |
| Integration harness (Docker) | only `test/integration/**` fails; compose/pull/health-check noise in log | registry pull hiccups, compose-up races, port publishing, dind storage driver — reproduce with `bin/test test/integration/<file>` repeated; check `compose_up_with_retry` and health-wait logic in `test/integration/integration_test.rb` |
| Stub/mock fragility | a Mocha stub that silently no-ops when internals change (`any_instance`, one-shot expectations) | read the stub, ask "what guarantees this intercepts?" — prefer making it self-verifying |
| CI-environment divergence | reproduces on CI never locally | diff `.github/workflows/ci.yml` env (storage driver, dind config, Ruby patch level) vs local |

## Phase 5: Reproduce (escalation ladder)

Stop at the first rung that reproduces; the rung itself narrows the class.

```bash
# 1. Exact: same seed as the failing run
bin/test <file> --seed <N>

# 2. Unit-suite context (order-dependence: the test may need company)
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }' -- --seed <N>

# 3. Stress loop (random seeds); exits nonzero if ANY run failed
status=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  bin/test <file> || { echo "FAIL i=$i"; status=1; }
done
exit "$status"
```

Integration tests: each run does a real compose up/down, so 10 iterations is expensive — start with 3 and scale up only if it stays green. `DEBUG_CONTAINER_LOGS=1` dumps per-container logs on failure (see `test/integration/integration_test.rb`).

Judge stress runs by **exit code**, not by grepping output — a load error can print `0 failures` while running 0 tests.

## Phase 6: Root-cause systematically

- Instrument before hypothesizing: print the actual state at the assertion point (printed SSHKit command stream, ENV, container state); log every call a suspect stub receives; verify a stub *engaged* rather than assuming it did.
- `git log`/`git blame` the test and the code under test — when written, what invariant it fenced, what changed since (especially upstream syncs).
- Map all the moving parts the test depends on (`test_helper.rb` setup/teardown, `SSHKit::Backend::Printer` swap, ENV seeding, fixtures) — the failure point is rarely the fix point.
- Write the mechanism in ONE sentence before touching code. If you can't, you haven't found it.

Hard rules: no `skip`, no retry-wrapping the assertion, no `sleep`, no assertion loosening, no `rescue nil`. Those hide the bug; it resurfaces somewhere more expensive. (Bounded retries around genuinely-external operations — an image pull, compose up — belong in the harness like `compose_up_with_retry`, never around the behavior under test.)

## Phase 7: Fix and stress-prove

1. Fix at the root (test infrastructure, code under test, or both). Prefer mechanisms that **cannot be silently defeated**: assertions that name the expected failure source so a no-op stub fails loudly; teardown that verifies cleanup happened.
2. **Fence check**: if the test is a regression fence, temporarily reintroduce the original bug and confirm the test goes red; restore.
3. **Stress gate**: ≥10 consecutive green runs with fresh random seeds (≥3 for integration tests), judged by exit code. Plus the exact original repro if Phase 5 found one.
4. Standard gates: `bundle exec rubocop --parallel`, unit suite green.

## Phase 8: Record

1. Append a dated entry to `docs/flaky-tests.md` (create it if missing): test, signature class, root cause (the one sentence), fix, reproduction recipe. Prune entries whose tests no longer exist.
2. Issues: if the fix ships now, reference and close any open `flaky-test` issue in the PR (`Closes #N`). If the flake can't be fixed now, create one: `gh issue create --repo zoolutions/dash --label flaky-test` with the evidence and recipe (create the label first if it doesn't exist).
3. If the investigation exposed something systemic (CI dind config, shared test helpers, upstream-sync interaction), file it as its own issue — don't bury it in the memory file.

Now begin with Phase 0 for: $ARGUMENTS
