---
description: "Drive a set of open dash PRs to merge-ready, one at a time, in a given order. Merges the base forward (never rebases — published branches are shared), runs /github-review-pr (conflicts, then CI failures, then review comments) on each, then waits for the user to merge before syncing and advancing to the next. Use to clear a stack of stacked/parallel PRs without manual merge churn."
model: opus
argument-hint: "ordered PR list (e.g. '12 14 15 18'); optional 'automerge' to enable gh auto-merge; empty = auto-discover your open PRs"
allowed-tools: Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr diff:*), Bash(gh pr comment:*), Bash(gh pr merge:*), Bash(gh api:*), Bash(gh run view:*), Bash(git:*), Bash(bundle:*), Bash(bundle exec:*), Bash(bundle install:*), Bash(bin/test:*), Bash(cd:*), Read, Write, Edit, Glob, Grep, Agent, Skill, TaskCreate, TaskUpdate, TaskGet, TaskList, ScheduleWakeup
---

# Finish PRs (ordered merge-ready loop): $ARGUMENTS

You are driving a set of open pull requests on `zoolutions/dash` (the `dash` gem) to **merge-ready** state, one at a time, in a defined order, minimizing the manual sync/CI back-and-forth that stacked or parallel PRs create.

## The fork constraints that shape this loop

This is a fork, and its branch model changes what "sync the PR" means. Read `.claude/rules/git-workflow.md` and `.claude/rules/upstream-sync.md` if you have not; the non-negotiables:

| Rule | Consequence for this command |
|---|---|
| PRs target `dash`, never `main` | The base you sync against is `origin/dash`. A PR with `baseRefName: main` is a bug — report it, don't process it. |
| **Never rebase a published branch** | Every branch here has a PR, so it is published. Sync with **`git merge origin/dash`**, never `git rebase`. There is therefore **no force-push anywhere in this command** — merge commits push cleanly. |
| Merging a PR lands on `dash`, not `main` | `main` doesn't move when a PR merges, so the *upstream* base is stable. What each merge invalidates is the others' relationship to `dash` — that's what the re-sync in Phase 2a absorbs. |
| `git rerere` is enabled | Previously-seen conflicts auto-replay their recorded resolutions. Always `git diff --staged` before trusting a replay — a resolution recorded in a different context can be wrong. |
| `feat/*` branches root off `main` | Merging `dash` forward into them is the normal, expected operation — it costs nothing and needs no note in the report. Upstreaming later extracts the feature's own diff (`git diff dash...feat/<feature>`, see `upstream-sync.md`), which already excludes everything `dash` contributed. |

**This command does NOT merge PRs itself** unless the user passed `automerge`. Default behavior: make each PR merge-ready, then pause and let the user merge; when a merge lands, re-sync the remaining PRs and continue.

**This command does not re-implement conflict resolution.** `/github-review-pr` owns that (its Phase A0), along with CI failures (Phase A) and review comments (Phase B). This command owns *ordering, sequencing, and the wait-for-merge gate*.

---

## Phase 0: Parse the PR list and order

`$ARGUMENTS` may be:

- A space/comma-separated ordered list of PR numbers: `12 14 15 18` (also accepts `#12`, `PR12`).
- The word `automerge` anywhere in the args → enable `gh pr merge --auto --squash` on each PR once it is green + approved (still respects branch protection; GitHub merges when gates pass). Strip it out before parsing numbers.
- Empty → auto-discover:

  ```bash
  gh pr list --repo zoolutions/dash --author=@me --base main --state=open --limit 100 \
    --json number,title,headRefName,baseRefName,createdAt
  ```

  Order **oldest-first** (`createdAt` ascending). The explicit `--limit` matters — `gh pr list` defaults to 30, so without it discovery silently drops older PRs once the queue grows past 30. Oldest-first is the safe default: the earliest PR is usually the one others were cut alongside, so merging it first minimizes downstream re-syncs. Show the discovered order and proceed.

**Verify every PR's base is `dash`.** Any PR based on `main` is a mistake in the fork model — surface it immediately and exclude it from the queue rather than processing it.

**Order matters.** Each merge into `main` invalidates the others' merge base against `main`. Processing in a fixed order means you merge the base forward into each remaining PR exactly once per upstream merge, not repeatedly. If the user gave an explicit order, honor it exactly — they may know a dependency the metadata doesn't show (e.g. a proxy-side change that must land first).

Create a task list (TaskCreate) with one task per PR, in order, so progress is visible. Mark the current PR `in_progress`.

Confirm the plan in one line: `Finishing N PRs in order: #a → #b → #c. Mode: <pause-for-merge | automerge>.`

---

## Phase 1: Locate each PR's working tree

For each PR you need a checkout of its branch to merge and push. Prefer, in order:

1. An existing worktree already on that branch: `git worktree list` — match the branch.
2. If none, create one: `git worktree add .claude/worktrees/finish-<PR> <branch>` (fetch the branch first: `git fetch origin <branch>`).

Never merge into a branch that is currently checked out in the **main working directory** — operate in a worktree so the user's main checkout is undisturbed. Never touch `main` at all.

---

## Phase 2: Per-PR loop

Process PRs strictly in order. For the current PR:

### 2a. Sync the branch onto the latest `dash`

```bash
git fetch origin main --quiet
cd <worktree>
git merge origin/dash
```

**Merge, never rebase.** If the merge conflicts, do NOT resolve it here — `/github-review-pr` Phase A0 owns conflict resolution and carries the per-file playbook (`lib/dash/version.rb` → base's side; `Gemfile.lock` → take either side then `bundle install`; `proxy/run.rb` → keep `ghcr.io/zoolutions/dash-proxy` and treat a `MINIMUM_VERSION` conflict as a release-ordering question; new multi-host fixtures → `loadbalancer: false`). Abort the merge (`git merge --abort`), and let step 2d handle it — Phase A0 runs first inside that command by design.

If the merge is clean, commit it (git's default merge message is fine) and continue.

### 2b. Settle `Gemfile.lock` if the merge disturbed it

`Gemfile.lock` is tracked at the repo root and is the one mechanically-resolvable file in this repo. If the merge touched it, or `git status` shows it dirty:

```bash
bundle install     # re-derives the lockfile
git add Gemfile.lock
```

Never hand-merge a lockfile. Confirm the diff is only dependency resolution, not a `kamal (X.Y.Z)` version line you didn't expect — the version is written only by `rake release` on `main`, so an unexpected bump on a feature branch is accidental and should be resolved to `main`'s value.

### 2c. Push the synced branch

```bash
git push origin <branch>
```

**No `--force`, no `--force-with-lease`** — this command never rewrites history, so a plain push always suffices. If a plain push is rejected, someone else pushed; fetch and merge again rather than reaching for force.

### 2d. Run the full review pass

Invoke `/github-review-pr <PR>` (via the Skill tool). It runs **conflicts (A0) → CI failures (A) → review comments (B)** — do not re-implement any of it. It will:

- Resolve any merge conflict with `dash` semantically, per the conflict playbook, and push the merge commit.
- Fix red CI checks (rubocop, unit tests, and `bin/test` when the change touches proxy/deploy paths) and push.
- Address every unresolved review thread: implement valid fixes, push back with reasoning on wrong ones, resolve threads.

Wait for it to finish. If it reports a persistent failure it could not fix (or a conflict it could not resolve without a decision), surface that for this PR and move it to a `needs-user` state — do not block the whole queue on one stuck PR; note it and continue to the next PR, then return.

Treat every `test/commands/builder_test.rb` failure as real (`.claude/rules/testing.md`) — those are host-arch artifacts, not PR defects. Confirm against CI; never "fix" the assertion to make them pass locally.

### 2e. Verify merge-ready

```bash
gh pr view <PR> --json mergeable,mergeStateStatus,reviewDecision,baseRefName \
  --jq '{mergeable,mergeStateStatus,reviewDecision,baseRefName}'
gh pr checks <PR>
```

Merge-ready means: `baseRefName=dash`, `mergeable=MERGEABLE`, no failing checks (green or pending-green), and `reviewDecision` is `APPROVED` or empty (not `CHANGES_REQUESTED`). A `BLOCKED` mergeStateStatus with everything else green usually means "awaiting required approval" — expected, not a defect.

`mergeable=UNKNOWN` is common right after a push and can persist for minutes. Don't poll it; verify locally per the `git merge-tree --write-tree --name-only origin/dash FETCH_HEAD` recipe in `/github-review-pr` Phase A0.

### 2f. Hand off for merge

- **`automerge` mode:** `gh pr merge <PR> --auto --squash` (GitHub merges when gates pass). Then go to Phase 3 to wait for the merge to land before advancing.
- **Default (pause) mode:** report this PR as ✅ merge-ready with its URL and a one-line "what's in it," and tell the user it's ready to merge. Then **wait** (Phase 3).

Mark the PR's task `completed` (merge-ready) — or `needs-user` via a metadata note if it got stuck in 2d.

---

## Phase 3: Wait for the merge, then advance

The loop is **gated on the target PR merging**, because each merge into `main` is what the next PR needs to absorb.

- **automerge mode:** poll `gh pr view <PR> --json state --jq .state` until `MERGED`. Use `ScheduleWakeup` with a delay matched to CI duration (unit + rubocop run a few minutes; `bin/test` with integration is much longer — poll ~300s, or ~900s if integration ran) rather than a busy sleep. When merged, advance.
- **default mode:** the user merges manually and will tell you (or you are re-invoked). On the next turn, re-check `gh pr view <PR> --json state`. If `MERGED`, advance to the next PR and repeat Phase 2 (its re-sync now picks up the just-merged changes). If not yet merged, report current status and stop — do not spin.

When you advance, **always re-fetch and merge `origin/dash` forward into the next PR** (Phase 2a) before doing anything else — the merge that just landed is exactly the change it needs to absorb.

If the user merges a PR **out of the planned order**, adapt: drop it from the remaining list and re-sync whatever is now next.

---

## Phase 4 (optional): upstream drift and release ordering

Two fork-specific things worth surfacing once, at the end, rather than fixing mid-queue:

- **Upstream drift.** If several PRs in the queue conflicted against `main` in the same file, `main` may have moved and `dash` may be behind it. The durable fix is the routine sync in `.claude/rules/upstream-sync.md` (`git checkout main && git merge --ff-only upstream/main`, then `git checkout main && git merge main`) — a commit to `dash`, so mention it, don't do it unprompted.
- **Release ordering.** If any PR in the queue moves `Dash::Configuration::Proxy::Run::MINIMUM_VERSION`, the referenced `ghcr.io/zoolutions/dash-proxy` tag must already be published — proxy image first, gem second. Flag it before the user merges, because merging a gem PR that names an unpublished proxy tag breaks integration tests on `dash`.

---

## Phase 5: Final report

When the queue is drained (all merged, or all merge-ready-and-handed-off, or blocked-on-user):

| PR | Result | Note |
|----|--------|------|
| #a | ✅ merged / ✅ merge-ready / ⏳ awaiting-merge / ⚠️ needs-user | one line |

Then:

1. What the user must do next (merge the ready ones, decide on any `needs-user` items).
2. Anything that complicates a later upstream extraction for a branch on the upstreamable list — e.g. unrelated fork-only changes committed onto the feature branch, which `git diff dash...feat/<feature>` would carry into the upstream PR.
3. Whether upstream drift or a `MINIMUM_VERSION` release-ordering issue (Phase 4) is worth acting on.

---

## Important notes

- **Never rebase anything** — every branch here is published; merge forward only.
- **Never force-push** — this command never rewrites history, so a plain `git push` always suffices.
- **Never touch `main`** — not a commit, not a merge, not a push. It is a fast-forward-only mirror of `basecamp/kamal`.
- **Never process a PR based on `main`** — report it as a fork-model mistake instead.
- **Never resolve conflicts here** — abort and let `/github-review-pr` Phase A0 do it with the full playbook.
- **Don't re-implement `/github-review-pr`, `/github-review-failures`, or `/github-review-comments`** — invoke them.
- **One stuck PR must not block the rest** — mark it `needs-user`, continue the queue, return to it in the final report.
- **Never hand-merge `Gemfile.lock`** — take a side, `bundle install`, commit the result.
- **Never hardcode a proxy version to make a test pass** — interpolate `MINIMUM_VERSION`.
