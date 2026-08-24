# dash Roadmap

Evidence-linked improvement roadmap for the dash fork (gem + [`../kamal-proxy`](https://github.com/zoolutions/dash-proxy) — its proxy-side twin lives in that repo's ROADMAP.md). Goal: bridge selected gaps vs nginx/traefik/caddy/envoy for kamal's audience — full-stack apps on their own servers — without competing head-on. Sequencing favors value per line changed.

## Strategic frame

- **Rejected upstream = safe moat.** Header rules (basecamp/kamal-proxy#62, #25), rate limiting (#20), compression (#19), caching (#7), PROXY protocol (#31) — basecamp said no; dash can own these without upstream ever colliding.
- **Stuck upstream PRs = cheap ports with waiting users.** On-demand TLS (kamal-proxy#63 — 18 months open, prod-tested), mTLS (#204), basic auth (#216 + gem-side kamal#1865), scale-to-zero (#197), min-TLS (#199), metrics excludes (#213).
- **Already-shipped dash differentiators**: SAN cert batching (upstream PR #185 unmerged), wildcard DNS-01 certs, the kamal-side loadbalancer CLI.
- **Out of scope**: static-file serving & HTTP caching (Thruster's lane; needs shared volumes), service mesh/xDS, K8s ingress. ACME EAB/alt-CAs (kamal-proxy#107): maintainer is receptive upstream — don't fork-invest.

## R1 — Foundations & fixes (gem 2.12.0.1 + proxy v0.9.2.2) — all S-sized

Gem-side fixes and exposure of already-built proxy capability:

| Item | Evidence / anchor |
|---|---|
| Loadbalancer propagates the full `Proxy#deploy_options` (reuse it — `Kamal::Commands::Loadbalancer` rebuilds flags from scratch today), respects `app_port` instead of hardcoded `:80`, respects `proxy.run.publish`/options | `lib/kamal/commands/loadbalancer.rb:19-20,37-48`; found via integration failures 2026-07-03 |
| Fix `bind_ips` validator checking the root key instead of `run.bind_ips` (validation is a no-op today) | `lib/kamal/configuration/validator/proxy.rb:27-28` |
| Add validation for the `loadbalancer:` key (must be `false`, `true`, or a proxy-role host) | validator has no entry today |
| Expose `healthcheck.port` / `healthcheck.host` in deploy.yml — merged proxy-side (kamal-proxy#152), never plumbed into YAML | kamal#1234 (11 comments), kamal#1842 |
| Expose `--tls-staging`, `--read-target` + writer-affinity knobs in deploy.yml | flag map in `lib/kamal/configuration/proxy.rb:91-123` |
| Expose `kamal-proxy rollout` as `kamal app rollout deploy/set/stop` — cookie-keyed canary is fully implemented proxy-side with zero gem surface (`grep rollout lib/` = 0 hits) | kamal#941 demand thread |
| Add `pre/post-proxy-deploy` hooks (none exist around the per-app proxy deploy) | hook inventory in `lib/kamal/cli/proxy.rb` |
| Docs: fill the accessory-proxy stub (`docs/accessory.yml:158-160`), fix stale run defaults (`docs/proxy.yml:174-175`) | — |

Proxy-side R1 items (bug fixes: cert renewal manager never started, cert metrics unwired, slowloris/server timeouts) — see `../kamal-proxy/ROADMAP.md`.

## DX & diagnostics thread (starts R1, continues every release)

Pattern language imported from pgbus (mhenrixon/pgbus issues):

| Item | pgbus precedent |
|---|---|
| `kamal doctor` — ssh/docker reachability, registry + ghcr auth, proxy version vs `MINIMUM_VERSION`, ports 80/443 free, cert expiry, DNS→host checks | pgbus#212 doctor CLI |
| Deploy/boot config banner — echo effective proxy config, incl. "loadbalancer auto-enabled (primary role has N hosts)"; the 2026-07-03 auto-LB surprise would have been visible | pgbus#213 boot banner |
| Eager config validation — fail fast before any ssh connection | pgbus#215 |
| Progress beacons during health-check waits (elapsed/attempts instead of 30s of silence) | pgbus#222 |

## R2 — Timeouts & resilience

| Item | Evidence | Size | Where |
|---|---|---|---|
| **Per-path/route timeouts** — per-`(host, path_prefix)` override of the target timeout, plus a true whole-request deadline (today `--target-timeout` is only a response-*header* timeout) | proxy#53; SSE cluster kamal-proxy#46/#54/#137/#186 | S-M | both — deploy.yml `path_timeouts:` map; proxy anchors in twin roadmap |
| Retries / hold-until-healthy — retry idempotent requests on the next target; hold briefly during redeploy blips (Caddy `lb_try_duration` pattern) | kamal-proxy#71 (16 comments); 4/4 big proxies | S | proxy |
| Custom error pages for upstream 502/503 (branded, not just maintenance mode) | kamal-proxy#49; 4/4 proxies | S | proxy |
| Upstream connection-pool / idle-timeout tuning knobs (all Go defaults today) | capability inventory | S | proxy |

## R3 — Security & access

| Item | Evidence | Size | Where |
|---|---|---|---|
| Basic auth per service/path | port kamal-proxy#216 + gem PR kamal#1865; kamal#1604 (23 reactions) | S | both |
| IP allow/deny (CIDR, per service/path) | discussions #143/#144; 4/4 proxies | S | both |
| Per-IP rate limiting (token bucket, burst, allowlist) | rejected upstream kamal-proxy#20 | S-M | both |
| PROXY protocol — real client IPs behind DO/AWS NLBs | rejected kamal-proxy#31, discussion #41 | S | proxy run flag + gem toggle |
| mTLS client certs — Cloudflare Authenticated Origin Pulls | port kamal-proxy#204; kamal#1628, #1484 | S-M | both |

## R4 — TLS & custom domains

| Item | Evidence | Size | Where |
|---|---|---|---|
| **On-demand TLS with `ask` endpoint** (Caddy-style SaaS custom domains) | port kamal-proxy#63 — 18mo open, 23 comments/18 reactions, prod-tested; discussions #141/#221; kamal#1617 | M | both — integrate with dash's CertificateRegistry, not the PR's standalone path |
| Min-TLS version / cipher config (HTTPS listener has no MinVersion today → Go's TLS 1.2 default) | port kamal-proxy#199 | S | proxy |
| Cert observability — expiry dashboards, renewal alerts (builds on R1 metrics wiring) | — | S | proxy |

## R5 — Traffic shaping & headers

| Item | Evidence | Size | Where |
|---|---|---|---|
| Header rules — request/response add/remove/set (CORS, HSTS, CSP presets) | rejected upstream kamal-proxy#62/#25; 4/4 proxies | S | both |
| Weighted canary split (`--target=b;weight=5`) extending the round-robin LB | kamal#941, kamal-proxy#8; 4/4 proxies | M | both |
| Redirect/rewrite rules (www→apex beyond canonical-host, SPA rewrites) | kamal-proxy#35; kamal discussions #1214, #97 | S-M | both |
| Compression (gzip/zstd/brotli) | rejected upstream kamal-proxy#19 | S | proxy + gem toggle |
| Scale-to-zero (idle stop, wake on request) | port kamal-proxy#197 | M | both — gauge demand first |
| Observability batch — access-log format selection, OTel traceparent, metrics path excludes | weak individual demand — bundle | S each | proxy |

## Sequencing rationale

R1 first: everything is S-sized, fixes real bugs, and exposes already-built capability (rollout!) — maximum value per line changed. R2 delivers the #1 pain (per-route timeouts) plus a coherent "timeouts story" no kamal-proxy user gets today without fronting nginx/traefik. R3 items are independent S-sized middlewares — good filler between larger efforts. R4's on-demand TLS is the single biggest differentiator (an existing user base is waiting on the stuck PR) but M-sized and touches dash's cert registry — schedule it for a focused block. R5 is a grab bag ordered by demand.

Version grammar: gem releases `2.12.0.N` (four-segment over the upstream base), proxy image tags `v0.9.2.N` until upstream tags a new base. Release ordering (proxy before gem) per `.claude/rules/upstream-sync.md`.
