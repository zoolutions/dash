---
description: "Executes full autonomous engineering workflow with verification. Use when implementing complete features, tackling GitHub issues, or running end-to-end fork development cycles."
model: opus
argument-hint: "GitHub issue number/URL or feature description"
allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(gh pr create:*), Bash(gh pr view:*), Bash(bundle exec:*), Bash(bin/test:*), Bash(rake release:*), Bash(git:*), Read, Write, Edit, Glob, Grep, Agent
---

# LFG - Full Autonomous Workflow

Execute a complete engineering workflow with verification at each phase. This is a fork: `main` mirrors basecamp/kamal and is never committed to directly. All work happens on a feature branch rooted off `main`, merged back into `main`. See `CLAUDE.md` and `.claude/rules/upstream-sync.md` for the branch model and release ordering — do not duplicate them here.

## Phase 0: Branch Setup

**BEFORE any other work, prepare the git branch — always root off `main`, never off `main`:**

1. Check the current branch: `git branch --show-current`
2. Switch to `dash` and sync it: `git checkout main && git pull origin main`
3. Create feature branch off `main`: `git checkout -b feat/{brief-description}` (or `issue-{number}-{brief-description}` if working a GitHub issue)

Rooting off `main` means the branch builds on the fork's real codebase — merged features, fork identity, and the `.claude/` toolkit are all present, so slash commands keep working and the branch merges back without replaying fork identity. The PR this workflow opens at the end targets `dash`, not `main`.

Upstreaming later is still possible from a `dash`-rooted branch — the "Upstreaming a feature" recipe in `upstream-sync.md` extracts the feature's own diff with `git diff dash...feat/<feature>`. Do not root off `main` to pre-empt that.

---

## Phase 1: Understand

### Step 1: Gather Requirements

If `$ARGUMENTS` is a GitHub issue number or URL:

```bash
gh issue view <number> --json title,body,labels,assignees,comments
```

If `$ARGUMENTS` is a description, use it directly.

### Step 2: Define Acceptance Criteria

**MANDATORY:** Write explicit acceptance criteria:

- **GIVEN** [context/setup]
- **WHEN** [action taken]
- **THEN** [expected outcome]

You MUST NOT proceed until you can articulate these clearly.

### Step 3: Comprehension Gate

Before proceeding, you must:

1. State the problem/feature in one sentence
2. Explain WHY this is needed (fork rationale — is this something upstream rejected, or a new dash-only capability?)
3. List what will change from the operator's perspective (`deploy.yml` keys, CLI flags, output)
4. Identify edge cases not explicitly mentioned
5. Explain the code path involved through the layer cake: `Dash::Cli::*` → `Dash::Commander` → `Dash::Commands::*` → `Dash::Configuration` → SSHKit

If you cannot complete ALL five items, investigate further.

### Step 4: Create Task List

Create a TaskCreate todo list with specific implementation steps.

---

## Phase 2: Explore

1. Find related files (Glob/Grep or Explore agent)
2. Read existing patterns in similar CLI commands under `lib/dash/cli/`
3. Understand dependencies and integration points across the layer cake (`lib/dash/commander.rb`, `lib/dash/commands/`, `lib/dash/configuration/`)
4. Check existing test coverage under `test/` (mirrors `lib/` structure; skip `test/integration` unless the change is deploy-path-sensitive)
5. If touching proxy behavior, review `lib/dash/configuration/proxy/` — `run.rb` owns `MINIMUM_VERSION` and the fork's default `ghcr.io/zoolutions/kamal-proxy` repository
6. If touching multi-host or load balancing, review `lib/dash/commands/loadbalancer.rb` and the `loadbalancer:` validation in `lib/dash/configuration/validator/proxy.rb` — the dash-only loadbalancer auto-activates for any primary role with >1 web host
7. Check `ROADMAP.md` for whether this item is already scoped (evidence-linked anchors, R1-R5 sequencing) — align implementation with the anchor's stated fix location

---

## Phase 3: Plan

1. List files to modify with specific changes
2. List new files to create with purpose
3. Identify whether this touches `lib/dash/version.rb` (only `rake release` writes it) or frozen server-artifact names (`.kamal/`, `kamal-proxy` container, `KAMAL_*` env) — if so, STOP and check CLAUDE.md's staged-rename table
4. Plan test coverage (TDD: tests FIRST), using minitest + mocha idioms already in `test/` — no RSpec
5. Update task list with implementation steps
6. Consider backwards compatibility with existing `deploy.yml` configs and the dash/upstream conflict playbook in `upstream-sync.md`

---

## Phase 4: Implement (TDD)

### The deviation log (keep it from the first edit)

The plan is the map; the codebase is the territory. The moment reality forces a choice the plan or issue didn't settle, log it in `implementation-notes.md` at the repo root — one line, at the moment it happens, not reconstructed later:

- **Deviations** — the plan said X, you did Y, because Z
- **Discoveries** — facts about the codebase the plan didn't know (a frozen server-artifact name in the path, a validator that no-ops, a fixture that needs `loadbalancer: false`)
- **Judgment calls** — choices the user might have made differently (defaults, `deploy.yml` key naming, scope cuts)

Pick the conservative option and keep going. The log is how the user audits your judgment afterwards. Never commit the file: its contents move into the PR body (Phase 7), then the file is deleted.

For each logical unit:

### 4.1: Write Failing Test First

Create a test that demonstrates the expected behavior. Run it to confirm it FAILS:

```bash
bundle exec ruby -Itest test/path/to/foo_test.rb
```

### 4.2: Implement Minimum Code

Write the MINIMUM code to make the test pass. Follow project patterns:

| Never Do | Always Do |
|----------|-----------|
| Hardcode a proxy version string in code or tests | Interpolate `Dash::Configuration::Proxy::Run::MINIMUM_VERSION` |
| Rename a frozen server artifact (`.kamal/`, `kamal-proxy` container, `KAMAL_*`) | Wait for the staged rename bridge — see CLAUDE.md |
| Add a `v*` git tag | Use `dash-v<version>` (gem) or coordinate with proxy's `v<base>.<n>` (image) |
| Skip Thor command conventions | Follow existing `lib/dash/cli/*.rb` patterns (options, hooks, `Dash::Cli::Base`) |
| Bypass `Dash::Commander` for target/config resolution | Route through `DASH` singleton (`Dash::Commander`) |
| Reference upstream proxy repository defaults | Default to `ghcr.io/zoolutions/kamal-proxy` per `lib/dash/configuration/proxy/run.rb` |
| Add a multi-host integration fixture without opting out | Set `loadbalancer: false` under `proxy:` — the dind harness can't resolve inner VM hostnames |

### 4.3: Refactor

Once green, refactor while keeping tests passing.

### 4.4: Validate

```bash
bundle exec rubocop --parallel <changed_files>
```

### 4.5: Repeat

Move to next logical unit. Mark task items complete.

---

## Phase 5: Deep Root Cause Analysis (Bug Fixes Only)

**If this is a bug fix, apply deep investigation before implementing:**

### Trace the Data Lifecycle

For the deploy/command causing the issue:
- Where in the layer cake did the wrong value originate — `Configuration` parsing, `Commander` resolution, `Commands` shell-out, or SSHKit execution?
- What ASSUMPTIONS does the code make at the failure point (host count, proxy version, env presence)?
- Which assumption was violated, and WHY?

### Use Git History

```bash
git log --oneline -20 <file>
git blame <file>
```

- When was the code written — is it fork-owned or inherited from upstream?
- Has a recent `git merge main` (upstream sync) changed behavior this code relied on? Check `.claude/rules/upstream-sync.md`'s conflict playbook for that file.

### Map All Callers

Don't just look at the method that failed:
- Use Grep to find all call sites across `lib/dash/cli/`, `lib/dash/commands/`, `lib/dash/configuration/`
- Does the error only happen with the loadbalancer active? The suite no longer varies with host architecture, so a failure is not an environment artifact.

### Five Whys

Keep asking WHY until you reach a meaningful fix point:

1. Error: X happened -> Why?
2. Because Y -> Why was Y in that state?
3. Because Z -> Why wasn't Z prevented?
4. Because no check existed -> Why not?
5. **THIS** is where the fix belongs

### Fix Location Principle

The best fix is usually NOT where the error is raised:
- Loadbalancer command missing a flag -> fix in `Dash::Commands::Loadbalancer` to reuse `Proxy#deploy_options`, not patch the call site
- Validator no-op -> fix the key path it reads (e.g. `run.bind_ips` vs root `bind_ips`), not add a second check downstream
- Version comparison breaks -> fix at `Dash::Utils.older_version?` / `MINIMUM_VERSION`, not at each call site

**Ask: "Where is the EARLIEST point I could prevent this error?" Fix there.**

### Unacceptable Superficial Fixes -- DO NOT DO THESE

- `rescue nil` without understanding why the exception occurs
- `&.` to silence nil errors without investigating why nil occurs
- `if object.present?` guards without understanding why missing
- Wrapping everything in `begin/rescue` to swallow SSHKit errors
- Hardcoding a proxy version to make a test pass instead of interpolating `MINIMUM_VERSION`

**These HIDE bugs. The root cause continues causing issues elsewhere.**

---

## Phase 6: Verify

**ALL of these must pass before committing:**

```bash
bundle exec rubocop --parallel                                                              # Style
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests
```

Run the full suite (`bin/test`, needs Docker + the published proxy image at `MINIMUM_VERSION`) only if the change touches deploy/proxy/integration paths. The suite is host-independent, so any local failure is real.

### Solution Verification

Re-read the original requirements and verify:
- "If I were the requester, would I consider this fully resolved?"
- "Have I addressed the ROOT CAUSE, not just the symptom?"
- "Do my tests prove the issue is ACTUALLY fixed, not just suppressed?"
- "Does this maintain backwards compatibility with existing `deploy.yml` configs?"
- "Did I avoid bumping `lib/dash/version.rb` (only `rake release` writes it) and renaming frozen server artifacts?"

---

## Phase 7: Commit & PR

### Commit

```bash
git add <specific_files>
git commit -m "$(cat <<'EOF'
feat(scope): brief description

## Summary
[What changed and why]

## Test Coverage
- test 1: validates requirement X
- test 2: validates edge case Y

## Verification
- [x] bundle exec rubocop --parallel passes
- [x] unit tests pass
EOF
)"
```

### Push & PR

PRs from this workflow target `dash`, not `main`:

```bash
git push -u origin $(git branch --show-current)

gh pr create --base main --title "feat(scope): brief description" --body "$(cat <<'EOF'
## Summary
- Key change 1 touching `lib/dash/commands/loadbalancer.rb`
- Key change 2

Closes #<issue_number>

## Test plan
- [ ] Scenario 1
- [ ] Scenario 2
EOF
)"
```

**Markdown inside the quoted heredoc is literal — do not escape.** The single-quoted `<<'EOF'` delimiter disables shell expansion on the body, so:

- Write backticks as backticks: `` `foo` ``. Do NOT write `\`foo\``; that writes a literal backslash-backtick and breaks the code span.
- Write dollar signs as-is: `$HOME`. No escaping needed.
- Write backslashes as-is: `\n` stays `\n`.

The body is copied verbatim into the PR / commit message. If you would not type a backslash in a GitHub comment, do not type one in the heredoc.

If the body is long or contains many backticks / tables, prefer writing it to a temp file and passing `--body-file`:

```bash
cat > /tmp/pr-body.md << 'EOF'
## Summary
...any markdown...
EOF
gh pr create --base main --title "..." --body-file /tmp/pr-body.md
rm /tmp/pr-body.md
```

The `--body-file` path avoids the double-layer of shell interpretation entirely and makes long PR bodies easier to read in the terminal buffer.

The PR body MUST end with a `## Deviations & judgment calls` section copied from
`implementation-notes.md` (then delete the file). If the plan held completely,
write "None — the plan held." This section is read FIRST in review — it is the
audit trail for every decision the plan didn't make.

If this feature is meant to be upstreamed later (rejected-by-basecamp features are NOT — see `ROADMAP.md`'s "safe moat" list), do nothing special here: the branch stays on `dash`, and the separate `pr/<feature>` extraction flow in `.claude/rules/upstream-sync.md` lifts the feature's own diff onto `main` when the time comes.

---

## Phase 8: Comprehension Close-Out

The tests prove the CODE is right; this phase keeps the USER's mental model right. After the PR is up, end your final message with:

1. **The decisions, not the diff** — the 3–5 non-obvious choices in this change someone must understand to maintain it. Lead with anything from the deviation log; the user has never seen those.
2. **Three merge-gate questions** the user should be able to answer before merging. If any answer isn't obvious to them, offer a walkthrough — an unanswerable question is comprehension debt, and merging anyway is how it compounds.

---

## Verification Checklist

- [ ] All acceptance criteria met
- [ ] Tests written BEFORE implementation
- [ ] `bundle exec rubocop --parallel` passes
- [ ] Unit test suite passes (full `bin/test` if proxy/deploy paths touched)
- [ ] Backwards compatibility with existing `deploy.yml` maintained
- [ ] No manual bump of `lib/dash/version.rb` (only `rake release` writes it), no frozen-artifact renames
- [ ] Branch rooted off `main`, PR opened against `main`
- [ ] PR body ends with `## Deviations & judgment calls` (from implementation-notes.md, since deleted)
- [ ] Comprehension close-out delivered (decisions + three merge-gate questions)

---

## Handoff

When complete:
- All phases executed
- Verification passed
- PR created against `main` and linked

Now, execute this workflow for the provided issue or feature.
