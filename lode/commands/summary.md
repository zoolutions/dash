# Command builders and the commander

The middle of the layer cake: `Dash::Commander` resolves what a command runs against, and `Dash::Commands::*` turns that into argv arrays. Nothing here opens an SSH connection — `Dash::Cli::*` splats these arrays into SSHKit's `execute` / `capture_with_info`.

## `Dash::Commander` (`lib/dash/commander.rb`, 258 lines)

The `DASH` singleton (`lib/dash.rb`). It holds the resolved config, the per-run `Timings` and `Report`, the verbosity, the lock flags, and memoised command builders.

- `#configure(**kwargs)` stores the arguments and clears the config; `#config` builds it lazily and, on first build, configures SSHKit from it (`configure_sshkit_with`, 221-232: pool idle timeout, `max_concurrent_starts`, `dns_retries`, ssh options, and `command_map[:docker] = "docker"` so the logs are not full of `/usr/bin/env`).
- `#specific_hosts=` / `#specific_roles=` filter through `Dash::Utils.filter_specific_items` (wildcards allowed) and **raise `ArgumentError` when a filter matches nothing** — a typo in `--hosts` must not silently deploy everywhere or nowhere. Both reset the memoised `Specifics`.
- `#reset` re-reads the lock flags from the environment through `env_flag("DASH_LOCK", "KAMAL_LOCK")` (255-257): the first name that is **set** wins, so `DASH_*` takes precedence over its legacy `KAMAL_*` twin rather than either merely being truthy. `Dash::Tags#env` writes both with the same value, so they disagree only when an operator sets one by hand.
- `#modify(command:, subcommand:)` (177-187) instruments the outermost frame as `modify.kamal` for the output loggers and closes the logger when the outermost frame ends; nested frames pass through.
- Builders are memoised in `@commands` when they take no per-call argument (`builder`, `docker`, `hook`, `lock`, `server_lock`, `loadbalancer`, `prune`, `registry`, `server`) and built fresh when they do (`app(role:, host:)`, `accessory(name)`, `auditor(**details)`, `proxy(host)`).

`Dash::Commander::Specifics` resolves `hosts`, `roles`, `primary_host`, `primary_role`, `roles_on`, `app_hosts`, `proxy_hosts`, `accessory_hosts` from the config narrowed by `--hosts`/`--roles`/`--primary`.

## `Dash::Commands::Base` (`lib/dash/commands/base.rb`, 262 lines)

The shell-composition vocabulary every builder uses. Each returns an array; none of them interpolates a value into a command string by hand.

| Helper | Joins with | Note |
|---|---|---|
| `combine` | `&&` (default) | drops the trailing combiner |
| `chain` | `;` | for "ask both questions whatever the first said" |
| `any` | `\|\|` | |
| `pipe` | `\|` | |
| `append` / `write` | `>>` / `>` | |
| `group` | `(` … `)` around an `&&` chain | `&&` and `\|\|` share precedence and associate left, so composing two builders that each mix them cannot be done flat |
| `substitute` | `$(…)` | |
| `xargs` | `xargs …` | |
| `shell` | `sh -c '…'` | single-quotes the payload and escapes embedded apostrophes (`gsub("'", "'\\\\''")`) — without it an apostrophe in an operator-supplied value (a `--resolver` name) would end the quoting and run whatever followed |

`confirmed_empty?` (51-53) is the codebase's answer to "is this container gone?". `! docker container inspect name >/dev/null 2>&1` cannot tell "no such container" from "the daemon could not be asked" — both exit non-zero — so it reads a transient failure as confirmed absence. A **listing** (`docker container ls --filter …`) exits 0 either way and non-zero only on a genuine failure, so `result=$(list) && [ -z "$result" ]` fails closed. Its argument must be a listing, never an inspect.

`ensure_run_directory` (85-87) is the `.kamal` → `.dash` migration plus the `mkdir`. It lives on `Base` because two unlocked paths reach the run directory before `Dash::Cli::Base#ensure_run_directory` does — the auditor records `Pulled image` during `build:pull`, and every `mkdir -p .dash/...` under it creates the parent. If any of them made the directory with a bare `mkdir`, `.dash` would exist by the time the guard ran and the legacy tree would be stranded, so everything that can be first runs the same command. It is idempotent, atomic (siblings in one filesystem, a rename not a copy), and invisible to running containers (a bind mount resolves to an inode). `test` leads deliberately: SSHKit's command map passes `if`/`test`/`time`/`exec` through untouched and prefixes everything else with `/usr/bin/env`. The trailing `|| true` keeps the exit status zero when there is nothing to migrate. The exact string is pinned once in `test/test_helper.rb` as `ENSURE_RUN_DIRECTORY`.

Readiness constants also live here, because both halves have to agree:

- `NO_HEALTHCHECK = "no-healthcheck"` prefixes the docker state when a container declares no healthcheck, so "nothing is probing this" stays distinguishable from "the probe passed" — both used to reach the poller as `running`.
- `READY_STATUSES = [ "healthy", "no-healthcheck:running" ]` is what the host-side wait stops on **and** what the poller accepts. A status the wait returned early for that the poller would not accept fails a boot the old client-side poll would have waited out.
- `EXEC_PROBE_FAILED` and `READINESS_PROGRESS_PREFIX` are wire formats read back by `Dash::Cli::Healthcheck::ProgressReporter`, not messages.

## `Dash::Commands::App#wait_for_ready` (`lib/dash/commands/app.rb`, lines 74-86)

The boot waits **on the host**: one round trip however long the container takes, where the client-side poll paid one per attempt. The loop echoes the status it stopped on to **stdout** — either a `READY_STATUSES` hit or the last status seen when the deadline passed — and writes progress to **stderr** once a second, so the capture's stdout is only ever the final status.

Reaching the deadline exits 0, because it is an answer the poller phrases. Only a status that could not be read at all exits non-zero: `readiness_probe` (lines 161-168) appends `|| exit $?` to the inspect and also checks for an **empty** status, because the read is a pipeline whose exit status is xargs', and xargs behaviour on empty input is not portable (GNU runs the utility anyway and exits 123; BSD and BusyBox skip it and exit 0). Both leave `$status` empty, and empty is not something a working `docker inspect --format` prints. An `exec:` probe is different: a non-zero exit **is** the answer "not ready", so its output is discarded and the loop continues.

`boot_state` and `stale_state` each fold two questions into one round trip, split on `BOOT_STATE_SEPARATOR` and chained with `;` rather than `&&` — an empty answer to either is a normal result and the second question must be asked whatever the first said.

## Proxy commands

`Dash::Commands::Proxy` (430 lines) and `Dash::Commands::Loadbalancer` (283 lines) build the proxy's `docker run`. Container, network, volume and image-title identities come from constants on `Dash::Configuration::Proxy` (`CONTAINER_NAME = "dash-proxy"`, `NETWORK = "dash"`, `CONFIG_VOLUME = "dash-proxy-config"`, `IMAGE_TITLE = "dash-proxy"`) with a `LEGACY_*` twin for each pre-rename name. `LEGACY_RENAME_MARKER = ".legacy-renamed"` records that a host has been through the bridge, so the sweep is a no-op afterwards.

`Dash::Commands::Proxy::CertTransfer` is shared by the proxy and loadbalancer builders. Archives leave through the apps-config bind mount — the one container path that is also a host path — and arrive through **stdin** into a one-off container: a bind-mounted source would need host permissions the container user cannot be guaranteed to have, and the store must be written as the image's own user or the proxy cannot read it. The import payload is built with `Base#shell`, so an apostrophe in a `--resolver` name cannot break out of the nested `sh -c` quoting.

## Invariants

- A builder returns an argv array; a CLI command splats it. No `execute "docker run … #{value}"`. The only string literals handed straight to `execute` are the two connection warm-ups, `execute "true"` (`lib/dash/cli/build.rb:221`, `lib/dash/cli/doctor/host_checks.rb:34`), which interpolate nothing.
- Operator-supplied values reach a shell only through `shell`, `argumentize` or `optionize`.
- Absence of a container is only ever concluded from a listing that succeeded (`confirmed_empty?`), never from a failed inspect.
- The host-side wait and the poller agree on `READY_STATUSES`.

## Related

- [../cli/summary.md](../cli/summary.md), [../configuration/summary.md](../configuration/summary.md)
- [../review/cli-and-proxy.md](../review/cli-and-proxy.md)
