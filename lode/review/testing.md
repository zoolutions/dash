# Review rules: tests that can actually fail

Accepted findings about `test/`. The suite layout, the helpers and the CI matrix are [../testing-and-ci/summary.md](../testing-and-ci/summary.md).

Every rule here came from one shape of review finding: **a test that passed for the wrong reason.** Before pinning a count or a call, revert the implementation and watch the test go red.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### A round-trip count taken on `execute_command` cannot see a capture
- **Holds because:** `recorded_commands` stubs `SSHKit::Backend::Printer#execute_command`, but a capture whose `capture_with_info` is stubbed is intercepted **above** the Printer and never arrives there. A test claiming "the clash check and the running-version read share one round trip" saw 8 commands and **0** of them carrying `BOOT_STATE_SEPARATOR`, because `boot_state` and `current_running_version` both go through `capture_with_info`. A count that must see captures counts those instead (`recorded_captures`), or both interleaved (`recorded_commands_and_captures`).
- **Where:** `test/cli/cli_test_case.rb#recorded_commands`, `#recorded_captures`, `#recorded_commands_and_captures`
- **Origin:** cubic learning 386ba845; PRs #159, #167

### Recording stops where the block does
- **Holds because:** the recording stub swallows the command instead of printing it, and mocha leaves an `any_instance` stub standing until the end of the test — so a second command run after the block was silently invisible (probed: a second prune in the same test printed no "Running" lines at all). `recorded_commands` unstubs in an `ensure`.
- **Where:** `test/cli/cli_test_case.rb#recorded_commands`
- **Origin:** PR #159

### The capture recorder matches with a matcher that returns **false**, and is set up last
- **Holds because:** a matcher that returns true consumes the call, and whichever stub was going to answer the capture never runs. Returning false records the call and lets the real expectation answer it. Mocha tries expectations newest first, so the recorder has to be registered after them.
- **Where:** `test/cli/cli_test_case.rb#recorded_captures`
- **Origin:** PR #167

### Order across hosts is not the gem's to promise; order within one host's list is
- **Holds because:** `on` runs hosts in parallel threads, so a pin that spells out host A's sequence and then host B's holds only while the threads happen not to overlap — CI seed 59404 interleaved them. `recorded_commands_and_captures` tags each round trip with its host so a test can group and assert per host.
- **Where:** `test/cli/cli_test_case.rb#recorded_commands_and_captures`
- **Origin:** PR #167

### A per-host count is asserted exactly, never by integer division
- **Holds because:** `2N+1 / N == 2` in integer division, so an extra command on any single host still passed a test whose whole purpose was pinning the per-host round-trip count. The commands are collected without host attribution in that test, so the exact total is what is pinned.
- **Where:** `test/cli/build_test.rb`
- **Origin:** PR #159

### A stub is not an assertion, and a stub on a path the fixture never reaches asserts nothing at all
- **Holds because:** `stub_capture` with `expect: false` does not require the capture to happen, so half of the readiness machinery was registered and unasserted. Adding `expect: true` made the test fail — the confirming read is never invoked at all, because `deploy_with_accessories.yml` sets `readiness_delay: 0` and the poller only re-confirms when the delay is positive. The stub was dead code. The same sweep found it in `test/cli/proxy_test.rb` (`deploy_with_proxy.yml`, also `readiness_delay: 0`).
- **Where:** `test/cli/main_test.rb`, `test/cli/proxy_test.rb`; `lib/dash/cli/healthcheck/poller.rb`
- **Origin:** PR #166

### A catch-all `stubs` alongside an `expects(...).with(...)` lets an extra call fall through
- **Holds because:** mocha sends the non-matching call to the stub, so even `.once` on the specific expectation would not have caught an extra per-vertex event. The OTel export tests capture every event and assert the whole set — the documented summary fields, the Dockerfile step fields, and that the export vertex emits no `dash.build.step`.
- **Where:** `test/output/otel_logger_test.rb:94`
- **Origin:** cubic learning 8e4179bd; PR #158

### A stub that answers the first write may never reach the code under test
- **Holds because:** a `File.write` stub fired on `prepare_directory`'s `.gitignore` write, and the test passed without ever reaching `publish`. Make the directory first, then stub what the publish itself does.
- **Where:** `test/report/writer_test.rb`
- **Origin:** PR #158

### Assert the lookup before the arithmetic that uses it
- **Holds because:** `nil + 1` replaces a readable assertion failure with a `NoMethodError` pointing at the wrong line. The index lookup is asserted first, and its message prints the lines it searched.
- **Where:** `test/cli/report_test.rb`
- **Origin:** PR #158

### Both halves of a compound key get a test
- **Holds because:** two tests exercising only the *error* dimension left the *label* half of the failed-step dedupe key unguarded. There are now three: same error on one step across platforms (one row), same error on different steps (two rows), different errors on one step (two rows).
- **Where:** `test/report_test.rb:74`, `:84`, `:93`
- **Origin:** PR #156

### A test that waits passes a timeout
- **Holds because:** a hang is strictly worse than a failure — the suite prints nothing at all. `Queue#pop(timeout:)` returns `nil` on timeout (it does not raise `ThreadError`), so the assertion is on the `nil`.
- **Where:** `test/sshkit_timing_test.rb`
- **Origin:** PR #155

### A proxy version in an assertion is `MINIMUM_VERSION`, including where a grep for a quoted string would miss it
- **Holds because:** the proxy image releases on its own schedule, so a literal breaks on every proxy release. A rename or registry sweep that greps only for plain quoted strings misses two sites: the regex literal in `test/integration/main_test.rb:72` and the shell variable in `test/integration/docker/deployer/setup.sh:35`. The one place a literal version is written on purpose is `test/fixtures/kamal_proxy_flags.yml`, and `test/proxy_flag_coverage_test.rb:66` fails while it disagrees with the constant — so forgetting `bin/sync-proxy-flags` after a bump is loud.
- **Where:** `.claude/rules/testing.md`; `test/proxy_flag_coverage_test.rb`
- **Origin:** cubic learnings 7adee2a7, 7fdbdd1e

### The suite must not depend on the host, and a local failure is therefore a real failure
- **Holds because:** four paths reached outside the process and each made the result depend on the machine: `Dash::Utils.docker_arch` (shelled out to `docker info`; `arm64` on Apple Silicon against amd64 fixtures, `""` with the daemon stopped), `Dash::Docker.included_files` (ran a real `docker buildx build`), `Dash::Dockerfile::Hadolint.available?` (a developer with hadolint installed saw different advice than CI), and the two verbosity globals a `-q`/`-v` CLI test leaves behind — nothing restores either between tests, and CI seed 36230 put `dash app stale_containers --quiet` ahead of the progress-reporter tests and silenced three of their assertions while other Ruby versions' seeds passed the same commit. All four are pinned in one `setup` block.
- **Where:** `test/test_helper.rb` (lines 70-92)
- **Origin:** PR #133; the verbosity half from the CI seed investigation

### A multi-host fixture that is not testing the loadbalancer sets `loadbalancer: false`
- **Holds because:** a primary role with more than one web host auto-activates the loadbalancer without anyone writing it down, and the Docker-in-Docker integration harness cannot support it — inner VM hostnames do not resolve inside the nested docker network.
- **Where:** `lib/dash/configuration/proxy.rb#effective_loadbalancer` (lines 243-251); `.claude/rules/testing.md`
- **Origin:** `.claude/rules/testing.md`, carried forward
