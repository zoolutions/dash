# Review rules: measuring the build and the SSH layer

Accepted findings about `lib/dash/build/`, `lib/dash/timings.rb`, `lib/dash/sshkit_with_ext.rb` and `lib/dash/output/otel_logger.rb`. The subsystem is [../observability/summary.md](../observability/summary.md).

**The safe direction here:** measurement rides on bytes and calls the process was already producing. A measurement that costs a deploy an extra round trip, a second process or an exception is worse than no measurement.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### `lib/dash/sshkit_with_ext.rb` must load and run with neither the autoloader nor `DASH` defined
- **Holds because:** the file is `require`-able on its own and its prepends apply to *everything* using SSHKit in the process, including code that never built a `Dash::Commander`. A bare `Dash::Timings.current_entry` in one hook raises `NameError` before any host runs — reproduced as `ruby -Ilib -e 'require "dash/sshkit_with_ext"; SSHKit::Runner::Parallel.new([SSHKit::Host.new("1.1.1.1")]) { }.execute'`. Every reach goes through the `DashTimings` helper (lines 14-28), whose three methods are each guarded with `defined?`, so the next hook cannot forget the guard.
- **Where:** `lib/dash/sshkit_with_ext.rb::DashTimings`
- **Proven by:** `test/sshkit_timing_test.rb` drives the patched backends directly
- **Origin:** cubic learning 8b15e279; PR #155

### A timing entry is handed across every thread dash spawns
- **Holds because:** the current entry is a thread-local, and a new thread starts with none of its parent's. Both places dash creates threads — SSHKit's per-host `Parallel` runner and `on_roles` — copy the entry in explicitly, or every command those threads issue is attributed to no phase at all.
- **Where:** `lib/dash/sshkit_with_ext.rb` `CompleteAll#execute` (lines 289-319), `SSHKitDslRoles#on_roles` (lines 374-412); `lib/dash/timings.rb::CURRENT_KEY`
- **Proven by:** `test/sshkit_timing_test.rb:47` ("a host thread inherits the entry that was current when the runner started"), `:77` ("roles run through on_roles inherit the current entry too")
- **Origin:** PR #155

### `TimedConnects` is prepended last, and an SSH connect is not counted as a round trip
- **Holds because:** prepended last it sits in front of the concurrency limiter and the DNS retries, so what a phase pays for a connection includes queueing behind `max_concurrent_starts` — which is what an operator is actually waiting on. The pool only calls through on a cache miss, so this measures real connects. `attribute_connect` adds to `connect_seconds` only, leaving `commands` alone: a connection is not a question asked of the host.
- **Where:** `lib/dash/sshkit_with_ext.rb::TimedConnects` (prepended at line 224); `lib/dash/timings.rb#attribute_connect`
- **Proven by:** `test/sshkit_timing_test.rb:93` ("an SSH connect is attributed to the current phase"), `:106`
- **Origin:** cubic learning c2cdf12a; PR #155

### Coverage for `TimedConnects` drives a real `SSHKit::Backend::Netssh` with `Net::SSH.start` stubbed
- **Holds because:** the whole suite runs on `SSHKit::Backend::Printer`, and a Printer never opens a connection — so the connect timing had no coverage at all while looking covered. The test stubs `Net::SSH.start` and asserts `connect_seconds` on the current phase.
- **Where:** `test/sshkit_timing_test.rb`
- **Origin:** cubic learning c2cdf12a; PR #155

### A test that waits on a queue passes a timeout, because a hang gives no output at all
- **Holds because:** a failing assertion names the problem; a hung suite prints nothing and is killed by the runner. `Queue#pop(timeout:)` returns `nil` on timeout rather than raising `ThreadError`, so the assertion is on the `nil`.
- **Where:** `test/sshkit_timing_test.rb`
- **Origin:** PR #155

### `ProgressParser` captures a parse error instead of raising it into the build
- **Holds because:** it is an SSHKit interaction handler sitting on a live `docker buildx build`. Raising would take down a build that is succeeding. The error lands on `@error`, parsing stops, and the caller reports it once and keeps everything collected up to that point. The stream arrives in packet-sized chunks rather than lines, so `#on_data` buffers and parses whole lines only, and `#finish` parses the trailing line a killed command leaves without a newline. Everything is behind a `Mutex`.
- **Where:** `lib/dash/build/progress_parser.rb#on_data`, `#finish` (lines 51-60)
- **Proven by:** `test/build/progress_parser_test.rb:108` ("data arriving in arbitrary chunks parses the same as whole lines"), `:121` ("a trailing line without a newline is still parsed"), `:129` ("a parse failure is captured rather than raised into the build")
- **Origin:** PR #156

### A mocha matcher must not be the thing that drives the parser
- **Holds because:** a `with { … }` block runs whenever mocha evaluates the expectation, which is not once per call in any order the test controls. `ProgressParser#parse_line` is idempotent for vertex creation (`@steps[number] ||=`) and for `DONE`/`CACHED`, but `pushing … done` **accumulates** into `@push_seconds` — so feeding the parser from a matcher double-counts it. Drive the parser from the test body and keep the matcher side-effect free.
- **Where:** `test/cli/build_test.rb`; `lib/dash/build/progress_parser.rb`
- **Origin:** PR #156

### `failed_steps` narrows to dockerfile steps and exports
- **Holds because:** BuildKit reports a cache-import miss as an `ERROR` on its own vertex, and the first build against a fresh cache always has one. Listing it as a failed step tells an operator their build broke when it did not.
- **Where:** `lib/dash/build/report.rb#failed_steps` (lines 82-84)
- **Proven by:** `test/build/progress_parser_test.rb:69` ("a failing step records the error and the report is still built")
- **Origin:** PR #156

### `Build::Report.from_h` restores only the steps and the push seconds, and recomputes the rest
- **Holds because:** a hand-edited file must not be able to claim a total its own steps do not add up to. Everything derivable is derived.
- **Where:** `lib/dash/build/report.rb#from_h`
- **Proven by:** `test/report_test.rb:232` ("from_h re-renders a saved report line for line")
- **Origin:** PR #158

### The OTel export emits `dash.build.step` for the operator's own Dockerfile steps only
- **Holds because:** the context, export and cache-export vertices are BuildKit's bookkeeping; they are already summarised on the `dash.build` event, and shipping them as steps would put rows in a chart the operator never wrote. `ship_build` iterates `build.dockerfile_steps`, not `build.steps`.
- **Where:** `lib/dash/output/otel_logger.rb#ship_build` (within `#ship_report`, lines 53-63)
- **Proven by:** `test/output/otel_logger_test.rb:94` ("the build ships one summary event and one event per Dockerfile step")
- **Origin:** cubic learning 8e4179bd; PR #158

### `#ship_report` cannot fail a deploy that already succeeded
- **Holds because:** the whole method is inside a `rescue StandardError` that costs one stderr line (and a backtrace only under `VERBOSE`). An OTLP endpoint being down is not a deploy failure.
- **Where:** `lib/dash/output/otel_logger.rb#ship_report` (lines 53-63)
- **Proven by:** `test/output/otel_logger_test.rb:136` ("a report that cannot be shipped costs one line on stderr")
- **Origin:** PR #158
