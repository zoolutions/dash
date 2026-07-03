---
description: "Use when a PR needs full review — fixes CI failures first, then addresses unresolved review comments. Run failures first because comment fixes trigger new CI runs that obscure the original failures."
model: opus
argument-hint: "PR number (e.g., 156 or #156)"
allowed-tools: Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr diff:*), Bash(gh pr comment:*), Bash(gh api:*), Bash(gh run view:*), Bash(git log:*), Bash(git blame:*), Bash(git diff:*), Bash(git push:*), Bash(git commit:*), Bash(git add:*), Bash(git fetch:*), Bash(bundle exec:*), Bash(bin/test:*), Read, Write, Edit, Glob, Grep, Agent
---

# Review GitHub PR (full pass): $ARGUMENTS

Full review pass on a dash PR. Two phases, strict order:

1. **Phase A: CI failures** — fix anything red before touching review comments.
2. **Phase B: review comments** — only after Phase A leaves CI green (or pending-green after a push).

## Why this order matters

Fixing review comments first means every commit kicks a new CI run. By the time comment fixes finish, the original failure logs are buried under newer runs:

- The failing-job log you needed is now stale; the latest run is still in progress on top of unrelated comment fixes.
- A comment fix accidentally repairs the CI failure as a side effect — you lose the chance to confirm the failure was real.
- A comment fix accidentally INTRODUCES a CI failure and you can't tell whether it's pre-existing or your fault.

Failures-first eliminates this: CI is either green or red on a known commit, and comment fixes layer cleanly on top.

## Phase 0: Determine the PR and remember the fork constraints

Parse `$ARGUMENTS` flexibly: `PR156`, `PR 156`, `156`, `#156` all mean PR 156. Empty/blank → auto-detect:

```bash
gh pr list --author=@me --head="$(git branch --show-current)" --state=open --json number,title
```

If exactly one open PR exists for the current branch, use it. If none or multiple, ask the user.

Confirm the PR and its base branch:

```bash
gh pr view <PR_NUMBER> --json title,state,url,baseRefName
```

**Before touching anything**, load the fork rules — they change what "correct" looks like on almost every file:

- `CLAUDE.md` — architecture (Thor CLI layer cake: `bin` → `Kamal::Cli` → `Commander` → `Commands` → `Configuration` → `SSHKit`), tooling, critical rules
- `.claude/rules/upstream-sync.md` — sync/release runbook, conflict playbook
- `.claude/rules/git-workflow.md` — branch model, tags, release ordering
- `.claude/rules/testing.md` — Minitest + Mocha conventions, `MINIMUM_VERSION` interpolation, known Apple-Silicon builder-test failures

Non-negotiables that apply to every fix in both phases below:

| Rule | Why |
|---|---|
| `baseRefName` must be `dash`, never `main` | `main` is a fast-forward-only mirror of `basecamp/kamal` — no commits, ever |
| Never edit `kamal.gemspec` or `bin/release` | upstream-owned, kept byte-identical so syncs don't conflict; the fork owns `dash.gemspec` / `bin/release-dash` |
| Never hardcode a proxy version in a test | interpolate `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION` — see `.claude/rules/testing.md` |
| Never `git push --tags` or a bare `v*` tag | fork tags are `dash-v<version>` (gem) / `v<base>.<n>` (proxy image); push one tag at a time |
| Never rebase `main`, `dash`, or a shared `feat/*` | merge forward only, history is shared |

---

## Phase A: Fix CI failures

1. **Identify failing checks**:
   ```bash
   gh pr checks <PR_NUMBER>
   ```
2. **Fetch logs for each failure**:
   ```bash
   gh run view <RUN_ID> --log-failed
   ```
3. **Diagnose root cause per failure.** Common categories on this repo:
   - **Rubocop** (`rubocop-rails-omakase`) — style violation, fastest to fix
   - **Unit test failure** — check first whether it's one of the two known Apple-Silicon-only `test/commands/builder_test.rb` failures (`.claude/rules/testing.md`); if so, confirm it also fails on a clean checkout of the PR's base and note it as pre-existing, don't "fix" the assertion
   - **Integration test failure** — needs Docker + the published proxy image at `ghcr.io/mhenrixon/kamal-proxy:$MINIMUM_VERSION`; if the image tag named by `MINIMUM_VERSION` isn't published yet, that's an environment/ordering issue, not a code bug — see `.claude/rules/upstream-sync.md` release ordering
   - **actionlint / zizmor** — workflow YAML issue in `.github/workflows/*`
   - **Multi-host fixture** — a new/changed fixture under `test/fixtures/` with a primary role that has >1 host must set `loadbalancer: false` under `proxy:`, or the loadbalancer auto-activates and the Docker-in-Docker harness can't resolve inner VM hostnames
4. **Fix locally, cheapest first**: rubocop → unit tests → integration/build issues.
5. **Verify locally before committing**:
   ```bash
   bundle exec rubocop --parallel
   bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
   # only if the failure was in integration, or before the final push to `dash`:
   bin/test
   ```
6. **Commit + push**, one focused commit per logical fix, conventional-commit style (`fix:`, `test:`, `ci:` — see `.claude/rules/git-workflow.md`). Then:
   ```bash
   gh pr checks <PR_NUMBER>
   ```
   Report which checks are now running.

### Phase A exit criteria

One of these must be true before moving to Phase B:

- All CI checks are green on the latest pushed commit. OR
- All CI checks are pending on the latest pushed commit, and none failed on the most recently completed run for that commit. OR
- A persistent failure exists that is **not caused by this branch's changes** (flaky `main`/`dash` job, an unpublished proxy tag blocking integration through no fault of this PR, a known Apple-Silicon builder-test artifact reproducible on base too). Report this explicitly and proceed to Phase B with the caveat noted.

If failures persist that trace to this branch's changes, **do not proceed to Phase B**. Report what's failing, what's been tried, and ask the user how to proceed.

---

## Phase B: Address review comments

1. **Fetch all unresolved review threads** via the GraphQL API:
   ```bash
   gh api graphql -f query='
     query($owner:String!,$repo:String!,$pr:Int!) {
       repository(owner:$owner,name:$repo) {
         pullRequest(number:$pr) {
           reviewThreads(first:100) {
             nodes {
               id isResolved
               comments(first:20) { nodes { id body path line author { login } } }
             }
           }
         }
       }
     }' -f owner=mhenrixon -f repo=kamal -F pr=<PR_NUMBER>
   ```
2. **Categorise each unresolved thread**: valid fix / invalid suggestion / unclear (ask the user for unclear ones).
3. **Implement accepted fixes**, respecting the architecture layers in `CLAUDE.md` — e.g. a Thor-option change belongs in `lib/kamal/cli/*`, a docker-command-string change in `lib/kamal/commands/*`, a deploy.yml-shape change in `lib/kamal/configuration/*`. Write/update the test first (RED → GREEN), per `.claude/rules/testing.md`.
4. **Verify locally**:
   ```bash
   bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
   bundle exec rubocop --parallel
   ```
5. **Commit all fixes together** with a clear conventional-commit message; push.
6. **Reply to every thread**:
   - Accepted fix → reply with the commit SHA.
   - Rejected suggestion → reply with technical reasoning (cite the fork rule if one applies, e.g. "keeps `kamal.gemspec` byte-identical to upstream per `.claude/rules/git-workflow.md`").
   ```bash
   gh api graphql -f query='mutation($id:ID!,$body:String!){ addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id, body:$body}) { comment { id } } }' -f id=<THREAD_ID> -f body="Fixed in <SHA>."
   ```
7. **Resolve each addressed thread**:
   ```bash
   gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' -f id=<THREAD_ID>
   ```
8. **Verify no unresolved threads remain** (re-run the query from step 1).

### Phase B exit criteria

- Every unresolved review thread has been replied to and resolved, or the user explicitly approved leaving a specific thread open.
- The branch has been pushed with all accepted fixes.

---

## Phase C: Final report

1. **Phase A summary** — which CI failures were diagnosed and fixed, with commit SHAs. Note any failure attributed to environment/pre-existing causes (unpublished proxy tag, known Apple-Silicon builder tests) instead of fixed.
2. **Phase B summary** — which comments were accepted (with SHAs), which were pushed back on (with reasoning), final unresolved-thread count (should be 0).
3. **Outstanding work** — e.g. CI still pending after the last push, or a proxy-image release needed on `../kamal-proxy` before integration can go green (release ordering: proxy image before gem, per `.claude/rules/upstream-sync.md`).

---

## Important Notes

- **Do not interleave the phases.** Don't fix a CI failure, then a comment, then another CI failure. The strict ordering is the entire point.
- **A new CI failure appearing during Phase B** (e.g. a comment fix breaks a test) means looping back to Phase A before continuing comment work — the only allowed reverse direction.
- **If the PR has no failures and no unresolved comments**, report "PR is clean" and stop.
- **Base branch must be `dash`.** If `gh pr view` shows `baseRefName: main`, stop and flag it — that PR is misdirected and needs retargeting before any review work.
- **Never let a comment fix touch `kamal.gemspec`, `bin/release`, or introduce a `v*`/hardcoded-proxy-version tag or literal** — these are the fork's hard constraints regardless of what the reviewer asked for; push back citing `.claude/rules/git-workflow.md` instead of complying.
