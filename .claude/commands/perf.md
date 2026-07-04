---
description: "Benchmark the current branch against main. Use when a change touches a proxy hot path (routing, TLS, service map) or gem-side command/config construction, or when asked to measure performance."
model: sonnet
argument-hint: "optional: go package or gem area to focus (e.g. internal/server, configuration)"
allowed-tools: Bash, Read, Write, Edit
---

# Performance Command

Measure, don't guess. This command produces a **same-machine before/after** so
any performance claim is backed by numbers. It covers both repos in the fork —
pick the one the change actually touches.

See `CLAUDE.md` (architecture) and `.claude/rules/upstream-sync.md` (worktree/branch
constraints) — this command follows their branch model, it doesn't repeat it.

## The non-negotiable rule

**Measure BEFORE you change.** A delta you didn't baseline is not a delta. If a
change already landed without a baseline, reconstruct one from `main` in a
worktree (below) — never report a number against a baseline from another machine
or another day.

**Never touch the primary tree to build the baseline.** The primary checkout on
this repo is normally `dash`; do not `git checkout main` in place — use a
worktree so the working tree you're actively editing is never disturbed.

## Which repo has bench

| Repo | Bench infra | Hot paths |
|---|---|---|
| `../kamal-proxy` (Go) | `make bench` → `go test -bench=. -benchmem -run=^# ./...` | routing, TLS termination, service map lookups (`internal/server/service_map_test.go` has real `func Benchmark*`) |
| this repo, `dash` gem (Ruby) | **none exists** — no `rake bench`, no `benchmark-ips` Gemfile dependency. Do not invent one. | see "Gem side" below |

## A. Proxy repo (Go) — real hot paths, `make bench`

### 1. Baseline `main` (before)

```bash
cd ../kamal-proxy
git worktree add --detach /tmp/kamal-proxy-baseline main
(cd /tmp/kamal-proxy-baseline && make bench) > /tmp/before.txt
```

### 2. Measure the branch (after)

```bash
make bench > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
git worktree remove --force /tmp/kamal-proxy-baseline
```

For a single package, use `go test -bench=. -benchmem -run=^# ./internal/server/...`
in both trees (swap the path via `$ARGUMENTS`).

### 3. Report honestly

- Report ns/op, B/op, and allocs/op — a routing-path change that adds allocs/op
  on the request hot path is a regression even if ns/op looks flat (GC pressure
  shows up under real load, not in a single-shot bench).
- If a number is within `go test -bench` run-to-run noise, say "within noise" —
  rerun with `-count=5` and `benchstat` before claiming a win.
- If you only measured *after* (no clean baseline), say so explicitly.

## B. Gem side (Ruby) — no bench suite, profile what actually costs time

`kamal deploy` runtime is dominated by network I/O (SSH exec on remote hosts,
`docker build`/`push`, proxy health polling) — not local Ruby. A
`benchmark-ips` micro-bench of, say, `Kamal::Commands::App#run` would measure
string-array construction that's noise next to a single SSH round-trip. Don't
build one. Two paths depending on what changed:

### B1. Local hot path (config load, command-array construction, Thor dispatch)

If the change touches `lib/kamal/configuration/**` or `lib/kamal/commands/**`
(YAML parsing, validation, SSHKit command building — all in-process, no
network), use a throwaway timing harness instead of a fabricated rake task:

```bash
git worktree add --detach /tmp/dash-baseline main
cd /tmp/dash-baseline && bundle install --quiet
bundle exec ruby -Itest -e '
  require "benchmark"
  require "kamal"
  N = 200
  fixture = Pathname.new(File.expand_path("test/fixtures/deploy.yml"))
  Benchmark.bmbm do |x|
    x.report("create_from") do
      N.times { Kamal::Configuration.create_from(config_file: fixture) }
    end
  end
' > /tmp/before.txt
cd -
# same script on the branch:
bundle exec ruby -Itest -e '...(same)...' > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
git worktree remove --force /tmp/dash-baseline
```

Swap the `Benchmark.bmbm` block body for whatever construction path
`$ARGUMENTS` names (e.g. `Kamal::Commands::App.new(...).run` for a command
builder change). Delete the script after — it's disposable, not committed.

### B2. Remote/deploy-shaped change (SSHKit command sequencing, hook ordering, proxy boot/health polling)

No local harness can measure this honestly — it's dominated by SSH latency and
Docker daemon time on the target host. Instead:

- Reproduce with the integration harness (`bin/test`, needs Docker + a published
  proxy image per `.claude/rules/upstream-sync.md`) and eyeball `print_runtime`
  output (`lib/kamal/cli/base.rb`) — every `deploy`/`redeploy`/`rollback`
  already wraps its critical section and prints `Finished all in N.N seconds`.
- Run the same scenario on `main` in a worktree and on the branch, same
  Docker-in-Docker host, and diff the printed runtimes. This is a wall-clock
  A/B, not a micro-bench — say so in the report.
- If the change adds/removes an SSH round-trip per host (e.g. an extra
  `on(KAMAL.hosts)` block), count round-trips directly by reading the diff —
  that's a more honest cost signal than a noisy timed run.

### 4. Report honestly (gem side)

- State explicitly which mode you used: **B1 (local micro-bench)** or **B2
  (wall-clock deploy timing)** — they are not comparable to each other.
- For B1, note this is Ruby object/array construction only — it does not
  predict deploy runtime.
- For B2, one run is an anecdote — rerun at least 3x and report the range, not
  a single number.
- If you only measured *after* (no clean baseline), say so explicitly.

## Keep perf continuous

- [ ] Proxy: if you touched a routing/TLS/service-map hot path, before/after
      `make bench` numbers are in the PR body.
- [ ] Gem: if you touched config/command construction, note whether it's
      B1 or B2 territory and include the comparison; if neither applies, say
      so instead of skipping silently.
- [ ] Cross-repo: if the proxy change ships first (per
      `.claude/rules/upstream-sync.md` release ordering), reference the proxy
      PR/tag in the gem PR body rather than re-pasting its numbers.

Argument (`$ARGUMENTS`): if a Go package or gem area is named, focus there —
`go test -bench=. -benchmem -run=^# ./$ARGUMENTS/...` for the proxy, or the
matching construction path for the gem's B1 harness; otherwise run the full
proxy `make bench` and, for the gem, ask which of B1/B2 applies before
fabricating a script.
