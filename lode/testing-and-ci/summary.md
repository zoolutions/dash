# Testing and CI

Minitest + Mocha under `ActiveSupport::TestCase`, never RSpec (`.claude/rules/testing.md`). **97** unit test files holding **1,919** `test "…"` blocks, plus **7** integration files that run real deploys in Docker.

## The split

| | Unit (`test/**` minus `test/integration`) | Integration (`test/integration/**`) |
|---|---|---|
| Docker | not needed | Docker-in-Docker deployer VMs |
| Proxy image | not needed | pulls `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION`; fails if unpublished |
| Command | `bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { \|f\| require File.expand_path(f) }'` | `bin/test` (runs everything) |

`bin/test` is five lines: it puts `test/` on the load path and requires `rails/plugin/test`.

## The suite must not depend on the host

`test/test_helper.rb` pins four things in one `setup` block (lines 70-92), each of which used to make the result depend on the machine:

| Pinned | Why |
|---|---|
| `Dash::Utils.docker_arch` → `"amd64"` | it shelled out to `docker info`, and tests derived their expected `--platform` from the answer. On Apple Silicon it returned `arm64` against amd64 fixtures — the long-standing "two builder tests fail on Apple Silicon" caveat — and with the daemon stopped it returned `""` and took five more tests with it |
| `Dash::Docker.included_files` → `[]` | it ran a real `docker buildx build` over the repo |
| `Dash::Dockerfile::Hadolint.available?` → `false` | `report: hadolint: auto` runs it when it is on `PATH`, so a developer who has it installed would see different advice than CI. `test/dockerfile/hadolint_test.rb` turns it back on |
| `DASH.verbosity` and `SSHKit.config.output_verbosity` → `:info` | a CLI test run with `-q`/`-v` leaves that verbosity on **both** globals, and nothing restores either between tests. CI seed 36230 put `dash app stale_containers --quiet` ahead of the progress-reporter tests and silenced three of their assertions, while the other Ruby versions' seeds passed the same commit |

**A local failure is a real failure.** If a test starts varying by machine again, look for a new call that reaches outside the process — Docker, the network, the clock — rather than adding it to a known-failures list.

SSHKit is swapped for `SSHKit::Backend::Printer` (remote **and** local, via a `run_locally` override), so assertions read the printed command string. Connection pooling is disabled and the eviction thread the default pool spawned at require time is killed, or it loops forever and trips over Mocha after teardown.

`ENSURE_RUN_DIRECTORY` is spelled out once in `test_helper.rb` (lines 98-101) — the `.kamal` → `.dash` migration plus the `mkdir` that every first-touching command emits — so a change to either half has to be deliberate.

## `CliTestCase` (`test/cli/cli_test_case.rb`, 191 lines)

Replaces the `DASH` constant with a fresh `Dash::Commander` per test, resets `Dash::Cli::Base.legacy_project_directory_warned`, stubs `load_balancing?` to false so auto-activation does not leak into unrelated tests, and points `reports_directory` at a tmpdir — without that the suite would write `.dash/reports` into this repository and the trend rules would start comparing test runs with each other.

Its recording helpers, and the trap each one exists for:

| Helper | Records | Trap |
|---|---|---|
| `recorded_commands` | what a caller `execute`s | a capture whose `capture_with_info` is stubbed is intercepted **above** the Printer and never arrives here, so a round-trip count that must see captures has to count those instead. The stub swallows the command instead of printing it, and mocha would leave it standing to the end of the test — so it is removed in an `ensure` and recording stops where the block does |
| `recorded_captures` | every `capture_with_info` | matches with a matcher that returns **false**, so whichever stub was going to answer still answers; mocha tries expectations newest first, so this has to be set up last |
| `recorded_commands_and_captures` | both, interleaved, tagged with the host | one shared array, because nesting the two gives two arrays and no ordering between them. `on` runs hosts in parallel threads, so the order **across** hosts is whatever the scheduler chose (CI seed 59404 interleaved them) — only the order within one host's list is the gem's to promise |
| `stub_capture` | answers one kind of capture and echoes it into the stream `stdouted` reads | a stubbed capture is never printed, so without the echo every assertion about what a boot ran goes blind the moment a command moves from `execute` to `capture` |
| `build_report_from_fixture` | a real `--progress=plain` log through the real parser | cheaper than a daemon and it proves the wiring end to end |

`test/fixtures/build/` holds four such logs: `progress_plain_success`, `_cached`, `_failed`, `_multiplatform`.

## Fixtures

**67** `deploy*.yml` files under `test/fixtures/`, one shape each. Four Dockerfile fixtures under `test/fixtures/dockerfiles/`: `naive_single_stage`, `rails_multistage`, `heredoc`, and a `context/` directory with its own `.dockerignore`.

A new fixture whose **primary role has more than one host** must set `loadbalancer: false` under `proxy:`, or the loadbalancer auto-activates and the Docker-in-Docker harness cannot support it (inner VM hostnames do not resolve inside the nested docker network).

## Proxy versions in assertions

Never a literal. Every assertion interpolates `Dash::Configuration::Proxy::Run::MINIMUM_VERSION`, because the proxy releases on its own schedule. Two of those sites are not plain quoted strings and a grep for one would miss them: the regex literal in `test/integration/main_test.rb:72` (`/ghcr\.io\/zoolutions\/dash-proxy:#{…MINIMUM_VERSION}/`) and the shell variable in `test/integration/docker/deployer/setup.sh:35`. The one place a literal version is written down on purpose is `test/fixtures/kamal_proxy_flags.yml`, and `test/proxy_flag_coverage_test.rb:66` fails while it disagrees with the constant.

`test/proxy_flag_coverage_test.rb` compares the gem's `deploy.yml` proxy surface against `test/fixtures/kamal_proxy_flags.yml`, the manifest `bin/sync-proxy-flags` generates from the image. It refuses to pass while the manifest names a different version, so forgetting to run it after moving `MINIMUM_VERSION` is loud rather than silent.

## CI (`.github/workflows/`)

| Workflow | Trigger | What |
|---|---|---|
| `ci.yml` | push to `main`, every PR, manual | `rubocop --parallel` (Ruby 3.3.0, `BUNDLE_ONLY=rubocop`); actionlint + zizmor; and `bin/test` across Ruby 3.2/3.3/3.4/4.0 × `Gemfile` and `gemfiles/rails_edge.gemfile`, excluding 3.2 × rails_edge — **7 test cells** |
| `docs-ci.yml` | `docs/**` changes only | inside `docs/`: icon sync, `bun install && bun run build:css`, `bundle exec rake lint`, `bundle exec rspec`. `BUNDLE_FROZEN: "false"`, because bundler 4 rejects the docs bundle's `path: ".."` gem in CI |
| `release.yml` | a published GitHub Release | rubocop + unit tests on Ruby 3.2 and 3.4, verify the tag matches `Dash::VERSION`, build, Sigstore-sign, trusted-publish to RubyGems |
| `deploy-docs.yml` | a published GitHub Release, or manual | deploys the docs site through the shared docs-kit reusable workflow |
| `docker-publish.yml` | — | publishes the repo's own image |

Every action is hash-pinned, zizmor runs over the workflows, and the release workflow deliberately skips `bundler-cache` because it publishes artifacts and a poisoned cache could reach them.

Two CI details that differ from a laptop: `Gemfile.lock` is **removed** before install, so every cell resolves fresh (hence `BUNDLE_RETRY: "6"`); and the runner's Docker is reconfigured onto `overlay2` at `/mnt/docker` before `bin/test`, because the integration suite fills the default disk.

## Release

`bin/release [patch|minor|major|X.Y.Z]` previews the bump and the commits since the last tag, requires a clean, up-to-date `main`, and hands off to `rake release[X.Y.Z]`. That task aborts on a dirty tree and then on the **proxy image gate** (`Rakefile:38-44`): `MINIMUM_VERSION` must be pullable from `ghcr.io/zoolutions/dash-proxy` or nothing else runs. Then it bumps `lib/dash/version.rb`, commits, pushes `main`, and creates the `vX.Y.Z` GitHub Release, which fires `release.yml` and `deploy-docs.yml`.

Tags are plain `vX.Y.Z`. Never a `-suffix` (`Gem::Version` parses `-` as a prerelease, which sorts **older** than the base and hard-fails `dash proxy boot`'s minimum-version check) and never `git push --tags`.

## Related

- [../workflow.md](../workflow.md) — the commands and CI facts the shared workflow skills read
- [../review/testing.md](../review/testing.md)
