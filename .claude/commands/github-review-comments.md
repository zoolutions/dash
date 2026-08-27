---
description: "Use when a PR has unresolved review comments that need responses -- evaluates each comment, implements valid fixes, pushes back on incorrect suggestions, and resolves all threads."
model: sonnet
argument-hint: "PR number (e.g., 123 or #123)"
allowed-tools: Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr comment:*), Bash(gh api:*), Bash(git log:*), Bash(git blame:*), Bash(git push:*), Bash(git commit:*), Bash(git add:*), Bash(bundle exec:*), Bash(bin/test:*), Read, Write, Edit, Glob, Grep, Agent
---

# Review GitHub PR Comments: $ARGUMENTS

You are reviewing and responding to all unresolved review comments on a GitHub pull request against `zoolutions/dash` (gem published as `dash`). Apply technical rigour -- evaluate each comment against the actual codebase before accepting or rejecting it.

**Fork context**: this repo is a maintained fork (see `CLAUDE.md`, `.claude/rules/upstream-sync.md`). A reviewer suggestion may be technically correct in general but wrong here because it collides with a fork constraint. Check the constraints table below before implementing anything.

## Phase 0: Determine the PR Number

The user may provide a PR number as `$ARGUMENTS`. Parse it flexibly:

- `PR123`, `PR 123`, `pr123` -> PR 123
- `123` -> PR 123
- `#123` -> PR 123
- Empty/blank -> auto-detect from current branch

**If no PR number is provided**, detect it automatically:

```bash
gh pr list --author=@me --head="$(git branch --show-current)" --state=open --json number,title
```

If exactly one open PR exists for the current branch, use it. If none or multiple, ask the user.

Once you have the PR number, confirm it and check the target branch:

```bash
gh pr view <PR_NUMBER> --json title,state,url,baseRefName
```

If `baseRefName` is `main`, stop and flag it -- PRs target `dash`, never `main` (see `.claude/rules/upstream-sync.md`). This command assumes a normal feature PR into `main`; do not proceed against `main`.

---

## Phase 1: Fetch All Unresolved Review Comments

Retrieve all review comments and identify unresolved ones:

```bash
# Get all review comments (not resolved)
gh api "repos/zoolutions/dash/pulls/<PR_NUMBER>/comments" --paginate

# Get all review threads to check resolution status
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            path
            line
            comments(first: 20) {
              nodes {
                id
                databaseId
                body
                author { login }
                createdAt
              }
            }
          }
        }
      }
    }
  }
' -f owner=mhenrixon -f repo=kamal -F pr=<PR_NUMBER>
```

For each unresolved thread, extract:
- Thread ID (for resolving)
- Comment body (the review feedback)
- File path and line number (if inline)
- Author (to understand context)

Filter to only **unresolved** threads. Skip bot comments (CodeRabbit, dependabot), resolved threads, and PR description comments.

If there are no unresolved review comments, report that and stop.

---

## Phase 2: Read and Categorise Each Comment

For each unresolved comment, read the full body and categorise it:

| Category | Action |
|----------|--------|
| Valid fix needed | Implement the fix |
| Valid test gap | Add the missing Minitest test |
| Valid style/consistency issue | Fix it |
| Incorrect suggestion | Push back with technical reasoning |
| Suggestion conflicts with fork architecture | Push back, reference the constraints table below |
| Suggestion renames a frozen server artifact | Push back -- see "Fork constraints" |
| Over-engineering / YAGNI | Push back, explain why it's unnecessary |
| Unclear | Ask for clarification (do NOT implement) |

**Before categorising**, always:
1. Read the actual file and line being commented on
2. Check if the suggestion is technically correct for THIS codebase (Thor CLI -> Commander -> Commands -> Configuration -> SSHKit layering, per `CLAUDE.md`)
3. Check if it would break existing functionality or an integration fixture
4. Check if existing patterns/conventions contradict the suggestion
5. Check `CLAUDE.md`, `.claude/rules/*.md` -- project conventions override reviewer preferences
6. Check the fork constraints table below -- a suggestion that's fine upstream can be wrong here

### Fork constraints (reject on sight if a comment proposes these)

| Reviewer suggestion | Why it's wrong here |
|---|---|
| "Just commit this fix to `main`" | `main` is a fast-forward-only mirror of `basecamp/kamal` -- never commit there |
| "Rename `.kamal/` / the `kamal-proxy` container / `KAMAL_*` env vars" | Frozen server artifacts — they wait for the staged rename bridge (see CLAUDE.md) |
| "Tag this `dash-v3.2.0`" | Gem tags are plain `vX.Y.Z` via `rake release`; `dash-v*` is frozen history |
| "Hardcode the proxy version string in the test" | Must interpolate `Dash::Configuration::Proxy::Run::MINIMUM_VERSION` -- see `.claude/rules/testing.md` |
| "Use a `-dash.1` style suffix for the proxy tag" | `Gem::Version` parses `-` as a prerelease marker, sorts BELOW the base, breaks `kamal proxy boot`'s version check |
| "Rebase your branch onto `dash`" | Feature branches root off `main` and merge it forward; never rebase a published branch |
| "This builder test failure needs fixing" | Agree and fix it — the suite is host-independent, so builder failures are real |
| "This multi-host fixture doesn't need `loadbalancer: false`" | The fork auto-activates the loadbalancer for any primary role with >1 web host; Docker-in-Docker integration VMs can't resolve each other's hostnames without it disabled |

---

## Phase 3: Implement Accepted Fixes

For all comments you've decided to accept:

1. **Make the code changes** -- edit the relevant files under `lib/dash/`
2. **Run affected unit tests** to verify nothing breaks:
   ```bash
   bundle exec ruby -Itest <relevant_test_file>
   ```
3. **Run the full unit suite** (no Docker needed):
   ```bash
   bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
   ```
4. **Run validators**:
   ```bash
   bundle exec rubocop --parallel
   ```
5. If the fix touches `lib/dash/configuration/proxy/**`, `Dash::Commander`, or loadbalancer auto-activation logic, treat it as critical-path -- confirm coverage per `.claude/rules/testing.md` (100% required) before moving on.
6. If the fix touches anything integration-relevant (deploy fixtures, proxy boot, multi-host roles), also run the full suite before pushing:
   ```bash
   bin/test
   ```
7. **Commit** all fixes together with a clear conventional-commit message (per `.claude/rules/git-workflow.md`):
   ```bash
   git commit -m "$(cat <<'EOF'
   fix: address PR review feedback

   - Description of fix 1
   - Description of fix 2
   EOF
   )"
   ```
8. **Push** to the remote branch:
   ```bash
   git push
   ```

Every builder test should pass; the suite no longer varies by host, so do not wave a failure away as an arch artifact.

---

## Phase 4: Reply to Every Comment

For **each** unresolved thread, reply:

### For accepted fixes:

Reply with what was fixed and the commit SHA:

```bash
gh api "repos/zoolutions/dash/pulls/<PR>/comments/<COMMENT_ID>/replies" \
  --method POST \
  -f 'body=Fixed in <SHA>. <Brief description of what changed>.'
```

### For rejected suggestions:

Reply with technical reasoning -- when the rejection is a fork constraint, cite it directly:

```bash
gh api "repos/zoolutions/dash/pulls/<PR>/comments/<COMMENT_ID>/replies" \
  --method POST \
  -f 'body=<Technical explanation, e.g. "Not applying -- the kamal-proxy container name is frozen until the staged rename ships a rolling-upgrade bridge (CLAUDE.md).">'
```

### Resolving threads (via GraphQL):

After replying, resolve the thread:

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }
' -f threadId=<THREAD_NODE_ID>
```

### For general PR comments (not inline review threads):

Reply directly:

```bash
gh pr comment <PR_NUMBER> --body "<Response addressing each point>"
```

---

## Phase 5: Verify Completion

After processing all comments, verify no unresolved threads remain:

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          totalCount
          nodes { isResolved }
        }
      }
    }
  }
' -f owner=mhenrixon -f repo=kamal -F pr=<PR_NUMBER>
```

Report the final tally: how many comments were accepted/fixed, how many were pushed back on (and which were fork-constraint rejections vs. technical disagreements), and confirm all threads are resolved.

---

## Response Style

When replying to comments:

- **No performative agreement** -- never say "Great point!" or "You're absolutely right!"
- **No gratitude** -- never say "Thanks for catching that"
- **Be direct** -- state the fix or the reasoning, nothing more
- **Reference commits** -- always include the short SHA when a fix was made
- **Be specific** -- when pushing back, reference actual code or the specific rule file, not abstract principles

When pushing back:

- Use technical reasoning grounded in the actual codebase
- Reference existing patterns if the suggestion contradicts them
- Reference `CLAUDE.md` / `.claude/rules/*.md` when applicable -- name the file
- Explain what would break (e.g. "breaks the upstream sync", "sorts below `MINIMUM_VERSION`", "fails the dind integration harness") or what edge case the reviewer missed
- If the suggestion is valid in principle but wrong for this fork, say so explicitly and point at the constraint

---

## Important Notes

- Always read the actual code before evaluating a comment -- reviewers sometimes misread diffs
- If a comment reveals a genuine bug you missed, fix it without defensiveness
- If multiple comments suggest the same change, implement it once and reference the fix in all replies
- Bot reviewers (CodeRabbit, etc.) sometimes suggest changes that conflict with fork conventions -- verify against `CLAUDE.md` and the constraints table above before accepting
- Bot reviewers will frequently suggest renaming frozen server artifacts, retagging with `dash-v*`, or fixing the arch-dependent builder tests -- these are the most common false positives; check the constraints table first
- If a new round of review comments appears after your push (from re-review), report that to the user rather than entering an infinite loop

Now begin by determining the PR number from `$ARGUMENTS` or the current branch.
