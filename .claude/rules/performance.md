# Performance Rules

dash is a CLI that shells out to SSH and Docker — the gem itself is not on a
request hot path. Kamal-proxy is. Where the two repos differ, this file says so.

## The prime directive

**Measure before you change. Measure after. Report both, honestly.**

A performance claim without a same-machine before/after is not allowed in a PR
or commit message. If you didn't baseline, say "measured after only" — never
imply a delta you didn't capture.

## Gem (this repo): no hot-path bench harness — say so

There is no `bench/` or `rake bench:*` here, and none should be invented for
this PR. `dash` runs once per `dash deploy`/`dash app boot` invocation and is
bounded by SSH round-trips and Docker daemon calls, not by Ruby CPU time —
shaving milliseconds off command-string construction is not a task that pays
for itself.

What still counts as "in scope" for this repo:

| Concern | Where | What to avoid |
|---|---|---|
| Command construction | `lib/kamal/commands/*.rb` (`docker.rb`, `app.rb`, `builder.rb`) | building the same `SSHKit::Command` args in a loop instead of once |
| Config resolution | `lib/kamal/configuration/*.rb` | re-parsing `deploy.yml` or re-walking roles per host instead of memoizing |
| Host fan-out | `Kamal::Commander`, `lib/kamal/cli/*.rb` | serial SSH where SSHKit's parallel host execution already applies |
| Loadbalancer activation | `lib/kamal/configuration/proxy/` (dash-only, auto-activates for >1 web host) | adding config lookups per-request — this is deploy-time only, never in the proxy's data path |

None of these have a bench script. If you touch one, reason about it in the
PR description (loop bound, N+1 SSH call, etc.) — don't invent a `Benchmark.bm`
harness for a one-shot CLI just to have a number to post.

## Proxy (kamal-proxy, sibling repo): the real hot path

Request routing, TLS handshake, and load balancing run per-request in
production and DO need before/after numbers. See
`../kamal-proxy/CLAUDE.md` and its own `.claude/rules/performance.md` if
present — summary for cross-repo awareness:

| Hot path | Bench coverage today |
|---|---|
| Host + path routing | `internal/server/service_map_test.go` (`func Benchmark*`) — the only benchmarked hot path |
| Request routing, proxy handler, load balancing, cert lookup | No benchmarks exist yet; add `func Benchmark*` in the relevant `_test.go` before claiming a perf delta |

```bash
make bench   # go test -bench=. -benchmem -run=^# ./...
```

Any PR touching those files in `kamal-proxy` needs a baseline-on-`main`,
change, re-bench, both numbers reported — same rule as the gem, just with an
actual harness to run.

## Always Do

1. **Baseline first** on whichever repo you're in — `main` HEAD for the gem,
   `main` HEAD for the proxy — before editing.
2. **Say which repo** a perf claim is about. "Faster" in the gem means fewer
   SSH round-trips or less config re-parsing; "faster" in the proxy means
   lower per-request latency or fewer allocations under `make bench`.
3. **Prefer SSHKit's built-in parallelism** over hand-rolled threading when
   fanning out across hosts — see `Kamal::Commander` for the existing pattern.
4. **Keep loadbalancer auto-activation cheap** — it's evaluated at deploy/config
   time (`>1 web host`), not per-request; don't let it grow into something that
   needs to be.

## Never Do

1. **Never claim a speedup without a measured before/after.** "This should be
   faster" is not a claim you're allowed to make in either repo.
2. **Never fabricate a benchmark harness for the gem** to satisfy this rule —
   if there's no hot path, the honest answer is "no bench, reasoned about the
   loop/call count instead."
3. **Never optimize gem-side Ruby at the expense of readability** — the
   command-builder layer (`lib/kamal/commands/`) is read far more often than
   it's profiled; three clear lines beat a clever one-liner for zero measured gain.
4. **Never trade a correctness invariant for speed** in either repo — proxy
   routing correctness and the gem's config validation are not negotiable.
5. **Never block on proxy perf work when releasing the gem** — release
   ordering (proxy image before gem, see `.claude/rules/upstream-sync.md`) is
   about `MINIMUM_VERSION` availability, not benchmark results.

## Performance Checklist (before marking perf work complete)

- [ ] Correct repo identified — gem (no harness) or proxy (`make bench`)
- [ ] Baseline captured BEFORE the change, same machine
- [ ] After numbers captured (proxy) or loop/call-count reasoning given (gem)
- [ ] Claim scoped honestly — "measured after only" if no baseline exists
- [ ] No correctness invariant traded for speed
- [ ] Unit tests still green (`bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'`)
- [ ] `bundle exec rubocop --parallel` clean
