# Workflow profile

Everything the shared workflow skills (`/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs`, `/lode:debug-flaky`, `/lode:tdd`, `/lode:plan`) need to know about this repository that is not already in `../CLAUDE.md`, `../.claude/rules/` or the rest of `lode/`.

## Commands

| Purpose | Command | Notes |
|---|---|---|
| fast loop (one file) | `bundle exec ruby -Itest test/<path>_test.rb` | no Docker, no network; `test/dockerfile/parser_test.rb` runs 22 tests in ~0.04s |
| full suite | `bin/test` | **needs Docker** (Docker-in-Docker deployer VMs) and pulls `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION`, which fails if that tag is unpublished. Not safe in two worktrees at once: the integration harness binds fixed ports and fills the docker disk |
| unit suite only | `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { \|f\| require File.expand_path(f) }'` | 97 files, 1,926 tests (Minitest's own count; a line-based count of `test "…"` says 1,919 because three files build tests in `each` loops), no Docker; safe in parallel worktrees |
| lint | `bundle exec rubocop --parallel` | rubocop-rails-omakase; `.rubocop.yml` at the root **excludes `docs/**/*`** |
| one CI cell locally | `BUNDLE_GEMFILE=gemfiles/rails_edge.gemfile bundle install && BUNDLE_GEMFILE=gemfiles/rails_edge.gemfile bin/test` | the matrix's only non-default dimension is the gemfile |
| docs build / check | `cd docs && bundle exec rake lint && bundle exec rspec` (add `bun install && bun run build:css` when CSS changed) | separate bundle; run from inside `docs/` |
| run the app | `bundle exec bin/dash help` (the gem installs `bin/dash` as the `dash` executable), or `bin/dash <command>` against a real `config/deploy.yml` | there is no local sandbox: dash deploys over SSH. `dash config`, `dash docs` and `dash report` are the safe read-only ones |
| release preview | `bin/release --dry-run` | prints the next version, the proxy tag it will gate on, and the commits since the last tag |

## Branches and PRs

- Default branch: `main` — the only long-lived branch. There is **no** `upstream` remote and no `dash` integration branch; the 2026-08 clean break (#115) removed both.
- Work branches: `feat/*`, `fix/*`, `refactor/*`, `chore/*`, `docs/*`, `ci/*`, rooted off fresh `origin/main`.
- Commits: conventional (`feat(scope):`, `fix:`, `refactor:`, `perf:`, `docs:`, `test:`, `chore:`, `ci:`); the body says **why**, and closes with `Refs #123`.
- PR body sections, in order: Summary, Test plan, Deviations & judgment calls, Gate. Plain Markdown — **never escape backticks**; with a single-quoted heredoc (`<<'EOF'`) they pass through verbatim, and for long bodies use `--body-file`.
- Open PRs with `--repo zoolutions/dash`.
- Merge policy: squash on `main` after green and approval. **Never rebase a published branch** — merge `main` forward into it. Never push directly to `main`.
- Attribution: end commit messages and PR bodies with whatever the session's own attribution reminder specifies. Do **not** add `Co-Authored-By: Claude` or "Generated with" lines.

## Layers

| Layer | Files | Edit rule |
|---|---|---|
| entry point | `bin/dash`, `exe/dash` | owned here; keep it to `Dash::Cli::Main.start` plus the one error-to-red-line rescue |
| CLI | `lib/dash/cli/**` | owned here. Parses options, orchestrates `on()` / `modify()` blocks. **Never** builds a docker argument string |
| commander | `lib/dash/commander.rb`, `commander/specifics.rb` | owned here. The `DASH` singleton: resolved config, per-run `Timings` and `Report`, memoised builders |
| command builders | `lib/dash/commands/**` | owned here. Returns argv arrays; **no SSH**, no `execute` |
| configuration | `lib/dash/configuration/**` | owned here. A new key needs a line in `lib/dash/configuration/docs/<section>.yml` or the validator rejects it as unknown |
| config docs | `lib/dash/configuration/docs/*.yml` | source of three things at once: the validator's example, `dash docs` output, and the generated docs pages. Change here, not in the generated page |
| measurement | `lib/dash/timings.rb`, `build/**`, `report/**`, `dockerfile/**`, `output/**` | owned here; fork-era-free. Everything in it must be unable to fail a deploy |
| SSHKit patches | `lib/dash/sshkit_with_ext.rb` | owned here, but it patches somebody else's library and must load without Zeitwerk and without `DASH` — every reach goes through `DashTimings` |
| docs site | `docs/**` | owned here, **separate bundle**. Configuration pages are generated — edit the YAML, not the page. Run its checks from inside `docs/` |
| generated | `test/fixtures/kamal_proxy_flags.yml` | regenerate with `bin/sync-proxy-flags`; never hand-edit |
| lockfiles | `Gemfile.lock`, `docs/Gemfile.lock`, `docs/bun.lock` | never hand-merge: take one side, then `bundle install` / `bun install` |

## Shapes

Check a change against these before calling it done.

- **Both asset paths through the parser:** a Dockerfile with a `# escape=` directive, with heredocs (terminated, unterminated, two on one instruction), with JSON exec forms, and empty.
- **A registry with a port** (`localhost:5000/app`) and **an interpolated tag** (`FROM ruby:$RUBY_VERSION`) — the two image-reference shapes that keep being got wrong.
- **A build report and no build report.** `dash doctor` and a `--skip-push` deploy have no measurements; every measured rule must stay silent, and every other rule must still fire.
- **A multi-platform build** — the same step reported once per platform, and a failure repeated per platform.
- **A single-stage Dockerfile** — buildx omits the stage label only there, which is the one case an unnamed vertex may match.
- **Multi-host primary role** — auto-activates the loadbalancer; a fixture that is not testing it sets `loadbalancer: false`.
- **A destination and no destination** — scopes the deploy lock, the report history and the report filenames, but never the proxy.
- **A host still on pre-rename identity** (`kamal-proxy` container, `kamal` network, `kamal-proxy-config` volume) versus one carrying `.legacy-renamed` — every container-creating proxy path must run the bridge.
- **A proxy that is running and one that is stopped** — `export_certs` reads through the RPC socket or offline; `import_certs` refuses a live proxy unless `--verify`.
- **A capture versus an execute** — a round-trip count that must see captures cannot be taken on `execute_command`.
- **Ruby 3.2 through 4.0, `Gemfile` and `gemfiles/rails_edge.gemfile`.**

## Constraints

Suggestions that are wrong in this repository. Push back on sight.

| Suggestion | Why it is wrong here |
|---|---|
| "Add an `upstream` remote / sync from basecamp/kamal" | The fork network was left in 2026-08 (#115). A basecamp fix arrives only by deliberate cherry-pick from a fresh clone |
| "Rebase the branch onto main" | Published branches are shared; merge `main` forward instead |
| "Build the docker command as a string, it is simpler" | Operator values reach a shell only through `Dash::Commands::Base#shell`, `argumentize` or `optionize` |
| "Use `! docker container inspect` to check the container is gone" | An inspect cannot tell "no such container" from "could not ask". Use `confirmed_empty?` on a listing |
| "Make the report raise so the operator notices" | The report is a courtesy; a broken report costs one yellow line. The only place it raises is `deploy.yml` validation |
| "Make the Dockerfile parser strict / raise on a file it cannot parse" | BuildKit is the authority on whether a Dockerfile builds. Wrong means *fewer* findings, never an exception |
| "Rename this rule class for clarity" | A rule id is a public string an operator writes in `report: ignore:` |
| "Hardcode the proxy tag in the test, the interpolation is noise" | The proxy releases on its own schedule; a literal breaks on every one |
| "Pin the exact command order across hosts" | `on` runs hosts in parallel threads. Only the order within one host's list is promised |
| "Stop the old container before copying its volume" | Every writer into the proxy's config volume writes atomically; stopping first only lengthens the outage |
| "Fix the duplicate bridge command in `Reboot#run`" | `dash proxy reboot` is reachable standalone, where nothing else has bridged. The command is guarded; the second run is a no-op |
| "Run rubocop over the whole tree including docs" | The root `.rubocop.yml` excludes `docs/**/*`; the docs app lints itself via `rake lint` with an explicit file list |

## Docs

- User-facing docs live in `docs/app/views/docs/pages/`, one `DocsUI::Page` subclass per page, each registered with a `page "…"` line in `docs/app/models/doc.rb`. The behaviour→page table is in [docs-site/summary.md](docs-site/summary.md).
- **Configuration pages are generated** from `lib/dash/configuration/docs/*.yml`. A new `deploy.yml` key means the YAML, not the page; a whole new section also means a `page` line and a `Config::` view class, or `docs/spec/config_docs_spec.rb` fails in one direction or the other.
- Changelog: **none.** This repository has no `CHANGELOG.md`; release notes live in the GitHub Release that `rake release` creates, and `docs/release-notes/` holds the site's own copies.
- A change to the deploy report's phases, build block, advice, trends or saved schema always updates `docs/app/views/docs/pages/deploy_report.rb` in the same PR.
- Files that pin a version and drift after a release: `docs/Gemfile.lock` (pins `dash (X.Y.Z)` through `path: ".."`) — `rake release` bumps it, but if it ever drifts, `cd docs && bundle install`. The saved-report example in `deploy_report.rb` carries a `dash_version` that goes stale by design.

## CI

- Workflows: `ci.yml` (push to `main`, every PR, manual) — RuboCop on Ruby 3.3.0 with `BUNDLE_ONLY=rubocop`; actionlint + zizmor; and `bin/test` across Ruby 3.2/3.3/3.4/4.0 × `Gemfile` and `gemfiles/rails_edge.gemfile`, excluding 3.2 × rails_edge. `docs-ci.yml` (only on `docs/**` changes). `release.yml` (a published Release). `deploy-docs.yml` (a published Release, or manual). `docker-publish.yml`.
- Matrix: 4 Ruby versions × 2 gemfiles − 1 exclusion = **7 test cells**, all named `Tests (Ruby X.Y)` — the job name does **not** carry the gemfile, so the two gemfile variants of one Ruby version share a name and have to be told apart by job id or by the `BUNDLE_GEMFILE` line in the log. Cells that differ from local: `Gemfile.lock` is **removed** before install so every cell resolves fresh (hence `BUNDLE_RETRY: "6"`), the runner's Docker is reconfigured onto `overlay2` at `/mnt/docker` before `bin/test`, and a `RUBYOPT: --enable=frozen-string-literal` is configured for Ruby 3.4 but never actually applies — the guard is `startsWith(matrix.ruby-version, '3.4.')` and the matrix value is `"3.4"`, so it is always the empty string.
- Fetch a failure: `gh run view <RUN_ID> --json jobs --jq '.jobs[] | {name, conclusion, databaseId}'` then `gh run view <RUN_ID> --job <JOB_ID> --log-failed`. Take the Minitest seed (`Run options: --seed N`) and the cell name out of the log — the same test failing in *all* cells is a regression, not a flake.
- "Green" means: RuboCop, the GitHub Actions audit, and all 7 test cells. `docs-ci.yml` only appears on PRs touching `docs/**`.
- Known not-this-branch failures: an unpublished `MINIMUM_VERSION` fails every integration cell identically and is a release-ordering problem, not a code one.
- Shared or rate-limited services the checks hit: the ghcr proxy image pull, and rubygems.org on every cell (nothing is cached across cells). Nothing is rate-limited per-account, so PRs need not run one at a time.

## Flake sources

- **The Docker-in-Docker integration harness** (`test/integration/**`): registry pull hiccups, `compose up` races, port publishing, and the dind storage driver. Only ever affects `test/integration`.
- **Per-test state leakage through globals**: `ENV["VERSION"]`, `ENV["KAMAL_*"]`/`ENV["DASH_*"]`, the `DASH` commander singleton, and — the one that actually bit — `DASH.verbosity` plus `SSHKit.config.output_verbosity`, which a `-q`/`-v` CLI test leaves behind and nothing restores. Reproduce with the failing run's `--seed`.
- **Thread and process leakage**: SSHKit's connection-pool eviction thread (killed in `test_helper.rb`), unkilled PTY children; the tell is an error in teardown or `Mocha::NotInitializedError`.
- **Parallel host threads**: `on` schedules hosts concurrently, so any assertion pinning an order *across* hosts is a latent flake (CI seed 59404).
- **Anything newly reaching outside the process** — Docker, the network, the clock. `test_helper.rb` pins the four known ones; a test that starts varying by machine means a fifth.
- Knowledge base: `docs/flaky-tests.md`, one entry per investigated failure; `gh issue list --repo zoolutions/dash --label flaky-test --state all`.

## Conflicts

| File | Rule |
|---|---|
| `Gemfile.lock`, `docs/Gemfile.lock` | never hand-merge: take either side, then `bundle install` (from the right directory) and commit the settled result |
| `docs/bun.lock` | take either side, then `cd docs && bun install` |
| `gemfiles/*.lock` | gitignored — nothing to resolve |
| `lib/dash/version.rb` | take the **base's** side. Only `rake release` writes it, on `main`; a bump on a feature branch is accidental |
| `lib/dash/configuration/proxy/run.rb` | keep the `ghcr.io/zoolutions/dash-proxy` repository. A `MINIMUM_VERSION` conflict is a release-ordering question (proxy image first), so flag it rather than picking a side |
| `test/fixtures/kamal_proxy_flags.yml` | generated — take either side and re-run `bin/sync-proxy-flags` |
| `test/cli/proxy_test.rb`, `test/commands/proxy_test.rb` | keep the ghcr org and the `#{…MINIMUM_VERSION}` interpolation; adopt the other side's new assertions around them |
| `test/integration/docker/deployer/setup.sh` | shell, not Ruby — keep the ghcr image and set its literal tag equal to `MINIMUM_VERSION` |
| `test/fixtures/deploy*.yml` | add a second fixture rather than merging two shapes into one; a multi-host primary role needs `loadbalancer: false` |
| `docs/app/models/doc.rb` | append-only, base order first; a duplicated `page` line is a drift-spec failure |
| `lib/dash/configuration/docs/*.yml` | union both sides' keys — this file is the validator's allow-list, so a dropped key becomes a rejected config |

Resolve every source file semantically: read both sides and produce the version that keeps both intents. Never blanket `--ours`/`--theirs`. If both sides rewrote the same logic and the right combination is not decidable from the code, **stop and ask** — a guessed resolution that compiles is worse than a question.

## Verification

- The manual check a user of this change would do: `bundle exec bin/dash config -c test/fixtures/deploy_simple.yml` for anything in `Configuration`; for the report path, run a unit test that renders a whole table (`test/report_test.rb`, `test/cli/report_test.rb`) and read the printed block — the report's contract *is* its printed text. For a command-builder change, read the printed command string the Printer backend produced.
- Prove every new test can fail: revert the implementation hunk and watch it go red. Three findings in this repo's history were tests that passed for the wrong reason.
- Stress iterations for a flake proof: **50** runs of the target file, plus one run of the whole unit suite at the failing `--seed` — order leakage needs the neighbours, not repetition.
- Where evidence goes: `lode/tmp/` (git-ignored, never committed). A flake that is worth remembering gets an entry in `docs/flaky-tests.md` instead.
