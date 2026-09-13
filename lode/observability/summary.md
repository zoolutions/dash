# Observability: timings, the SSHKit patches, and the output loggers

How a deploy knows where its time went, and where that goes besides the terminal.

## `Dash::Timings` (`lib/dash/timings.rb`, 198 lines)

Wall-clock accounting for a run, printed under `Finished all in`. The total alone says nothing: a serialised boot, a slow pull and a proxy waiting on a health check all look the same from the outside.

`Entry` is a `Struct` of `name, seconds, detail, depth, parent, commands, command_seconds, connect_seconds, local`. Entries land in **start order** with a depth, so a parent phase (`Boot`) prints above the per-host rows it wraps even though the hosts finish first. Boot runs one thread per host, so every mutation is behind `@mutex`.

- `#phase(name, depth:)` (59-74) times a block, marks its entry current for the duration and restores the previous one in an inner `ensure`; the outer `ensure` records the elapsed seconds even when the block raised. The entry is yielded, so a caller can annotate it (`Dash::Cli::Main#deploy` uses the yielded entry as `DASH.report.build_entry`).
- `#record(name, seconds)` (78-84) is for time measured before there was a `Timings` to record into — `Dash::Cli::Base#record_startup_timing` charges everything from `Dash::PROCESS_STARTED_AT` to the first phase as `Startup (load, config)`, which is the one row an operator cannot influence from `deploy.yml`.
- `#attribute_command(seconds, local:)` (90-100) increments the current entry's `commands` and `command_seconds`. `local` is `&&=`d, so a phase that issued even one remote command is reported `ssh` — the `local` label is only honest when nothing left the machine.
- `#subtree_totals` (174-193) rolls each entry's counters up through its `parent` chain **at render time**, keyed on `object_id`. A parent phase issues few commands of its own (Boot opens threads and waits), so its own counters say nothing; doing this at record time would leave the host rows without their own numbers.
- `#seconds_for(name)` and `Trends#phase_seconds` both filter on `depth == 0`, because a per-host row inside Boot is named after the host and a role could be named `Boot`.

### Attribution across threads

The current entry is a **thread-local** (`CURRENT_KEY = :dash_timing_entry`), reachable through class methods because the SSHKit patches run without a commander in reach. A new thread starts with none of its parent's thread-locals, so the entry is handed over explicitly at both places dash spawns threads:

| Site | File |
|---|---|
| per-host threads | `SSHKit::Runner::Parallel` → `CompleteAll#execute` (`sshkit_with_ext.rb`, lines 289-319) |
| per-role threads | `SSHKit::DSL#on_roles` (`sshkit_with_ext.rb`, lines 374-412) |

## `lib/dash/sshkit_with_ext.rb` (415 lines)

One file of `prepend`ed modules over SSHKit and net-ssh. It can be required on its own — without Zeitwerk and without the `DASH` commander — and it runs for everything else using SSHKit in the process. So **every reach into dash's runtime goes through the `DashTimings` helper at the top** (lines 14-28), whose three methods are each guarded with `defined?`. A guard forgotten at one hook would raise `NameError` before any host ran; funnelling them means the next hook cannot forget.

What the file adds, in prepend order where that matters:

| Module | Target | What it does |
|---|---|---|
| `CommandEnvMerge` | `SSHKit::Backend::Abstract` | merges default command options / env |
| `TimedCommands` | `SSHKit::Backend::Abstract` | times `create_command_and_execute` and calls `attribute_command`, with `local:` from `host&.local?` |
| `ConnectSsh` | `Netssh` | **included**, not prepended: the base `connect_ssh` the three prepended overrides `super` into, so the chain has a floor whatever SSHKit's own shape is |
| `DnsRetriable` / `DnsRetriableConnection` | `Netssh` | bounded retry with jitter on resolver failures |
| `LimitConcurrentStarts{Class,Instance}` | `Netssh` | a semaphore over `max_concurrent_starts` |
| `TimedConnects` | `Netssh` | prepended **last**, so it sits in front of the limiter and the retries: what a phase pays for a connection includes queueing. The pool only calls through on a cache miss, so this measures real connects |
| `ReconnectOnStaleConnection` | `Netssh` | evicts a pooled session that a NAT dropped while dash was busy elsewhere, and reconnects once |
| `CompleteAll` | `SSHKit::Runner::Parallel` | waits for every host thread and aggregates the exceptions instead of raising the first |
| `NoTrailingWait` | `SSHKit::Runner::Group` | drops the sleep after the last slice — there is no next group to pace against |
| `NetSshForwardingNoPuts` | `Net::SSH::Service::Forward` | silences net-ssh's debug `puts` |
| `SSHKitDslRoles` | `SSHKit::DSL` | `on_roles`, which lets one host hold concurrent connections for several roles |

A connect is **not** counted as a round trip: `attribute_connect` adds to `connect_seconds` only, leaving `commands` alone.

## Output loggers (`lib/dash/output/`)

`Dash::Commander#configure_output_with` (lines 234-245) broadcasts `config.output.loggers` into an `ActiveSupport::BroadcastLogger` and installs `Dash::Output::Formatter` as SSHKit's output. Setup failures print to stderr and are swallowed — logging must not be the reason a deploy cannot start.

`Dash::Output::FileLogger` writes a local file. `Dash::Output::OtelLogger` (122 lines) ships to an OTLP endpoint through `Dash::OtelShipper`. It subscribes to the `modify.kamal` notification (`Commander#modify`, lines 177-187) and emits `kamal.start`, then `kamal.complete` or `kamal.failed`.

`#ship_report` (53-63) then exports the same numbers the table printed, as events a backend can chart across deploys:

| Event | One per | Notable attributes |
|---|---|---|
| `dash.phase` | timing entry | `name`, `depth`, `seconds`, `detail`, `commands`, `command_seconds`, `connect_seconds` |
| `dash.build` | build report | `context_bytes`, `context_seconds`, `cached_steps`, `total_steps`, `export_seconds`, `cache_export_seconds`, `push_seconds` |
| `dash.build.step` | **dockerfile step** only | `stage`, `ordinal`, `instruction`, `seconds`, `cached` |
| `dash.advice` | finding | `rule`, `severity`, `location`, `message` |

`ship_build` iterates `build.dockerfile_steps`, not `build.steps`, so the export and context vertices ship the summary but no step event. `deployment.*` attributes are added only for `DEPLOY_COMMANDS` (`deploy`, `redeploy`, `rollback`, `setup`). The whole method is inside a `rescue StandardError` that costs one stderr line: shipping must never fail a deploy that already succeeded.

## Invariants

- Every reach from `sshkit_with_ext.rb` into `Dash::` goes through `DashTimings`; the file must load and work with neither the autoloader nor `DASH` defined.
- A timing entry is handed across every thread dash spawns, or the commands run there are attributed to no phase.
- `connect_seconds` and `commands` are separate: a connect is not a round trip.
- OTel step events cover the operator's own Dockerfile steps only.

## Related

- [../reports/summary.md](../reports/summary.md) — what the table and the JSON are made of
- [../review/build-measurement.md](../review/build-measurement.md)
