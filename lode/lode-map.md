# Lode map

The index of this repository's durable memory. Read this first; it beats a directory listing. Every file describes dash as it is now, with the reasoning behind it — never what changed.

- `summary.md` — what dash is, the clean break from kamal, the three invariants
- `terminology.md` — the words this repo uses (destination, run directory, bridge, readiness source, subtree total, shipped stage, measured rule, schema 1…)
- `practices.md` — the practices review taught that `../.claude/rules/` does not state: naming the safe failure direction, grammar tables for scanners, failing closed on an unreadable answer, atomic publishes, tests that can actually fail
- `workflow.md` — the profile the shared `/lode:*` workflow skills read: commands, branches, layers, input shapes, wrong-here suggestions, docs, CI, flake sources, conflict rules, verification
- `plans/README.md` — plans live in GitHub issues; `ROADMAP.md` holds the standing list

## Subsystems

- `cli/summary.md` — `Dash::Cli::*`: the Thor tree, `Base`'s class options, the two locks and their ordering, hooks, the report lifecycle's entry points, `deploy` step by step, `doctor`, `build`, and the 728-line `proxy` command file including the certificate paths
- `commands/summary.md` — `Dash::Commander` (the `DASH` singleton, target resolution, SSHKit configuration) and `Dash::Commands::*`: the shell-composition vocabulary, `confirmed_empty?`, the host-side readiness wait, the proxy identity constants and `CertTransfer`
- `configuration/summary.md` — `deploy.yml` into objects: loading and eager validation, the 15 commented-YAML docs the validator checks against, the `report:` block, the proxy identity constants, `effective_loadbalancer`, the config digest, secrets and their 10 adapters
- `dockerfile-advice/summary.md` — `lib/dash/dockerfile/`: the parser's constants and its **grammar table**, the analysis `Context`, all 15 rules with severities and thresholds, hadolint's four outcomes
- `reports/summary.md` — measure, render, save, compare: the report lifecycle in `Cli::Base`, `Dash::Report`'s rendering, `Build::ProgressParser` and `Build::Report`, `History`, the atomic `Writer`, `Trends`, and `dash report`
- `observability/summary.md` — `Dash::Timings`, the `prepend`ed SSHKit/net-ssh modules that attribute every round trip and connect, and the output loggers including the OTel export
- `testing-and-ci/summary.md` — the unit/integration split, what `test_helper.rb` pins and why, `CliTestCase`'s recording helpers, fixtures, the proxy-version discipline, the five workflows, and `bin/release`
- `docs-site/summary.md` — the docs-kit app in `docs/`: behaviour→page table, the generated Configuration group, its own checks, and how it deploys with the gem

## Review rules (`review/`)

Accepted review findings rewritten as rules about the system, each verified against the current code. `/lode:gate` reads every file here before reviewing a diff; `/lode:learn` adds to them.

- `review/dockerfile-parsing.md` — heredoc recovery, registry ports, interpolated tags, stage inheritance, apt option stepping, buildx step matching, exec-form handling, `.dockerignore` normalisation, one *Not a bug*
- `review/dockerfile-rules.md` — scratch, root-user wording, ENV/ARG secret forms, cache-busting references, `g++`, curl-pipe-shell, env blobs, cache targets, `mode=max`, apt segments, measured-rule silence, hadolint's four outcomes, two *Not a bug*s
- `review/reports.md` — the atomic publish and its no-hard-link fallback, validation by rendering, numeric collision ordering, which frame `status` describes, `--last` scoping, trend windows, `n/a` over a fabricated `0.0s`, the `[label, error]` dedupe key
- `review/build-measurement.md` — `DashTimings` guards, thread hand-off, `TimedConnects` ordering, parse errors captured not raised, matchers with side effects, `failed_steps` narrowing, OTel step events
- `review/cli-and-proxy.md` — `confirmed_empty?`, the readiness probe's exit-code and empty-status checks, xargs portability, the stderr-only progress reporter, certificates under lock and in `ensure`, the parenthesised `|| true`, server-lock rollback, two *Not a bug*s
- `review/config-and-secrets.md` — the three settings that raise at config time rather than reading as "off", and ACME DNS zone validation
- `review/testing.md` — capture-layer counting, recording that stops with its block, exact per-host counts, stubs that assert nothing, catch-all mocha stubs, host-independence, multi-host fixtures
- `review/docs-and-release.md` — examples that point into arrays, trend wording, `status` wording, measured-rule wording, tag hygiene, the proxy-image gate, the docs bundle's deliberate unfreeze

## Not memory

- `tmp/` — git-ignored: gate diffs and reports, handovers, scratch
