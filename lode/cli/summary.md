# The CLI layer: `Dash::Cli::*`

Thor commands. They parse options and orchestrate `on()` / `modify()` blocks; they do not build docker arguments and they do not run SSHKit calls from a `Commands` class (`.claude/rules/coding-style.md`). `bin/dash` requires `dash`, calls `Dash::Cli::Main.start(ARGV)`, and turns an `SSHKit::Runner::ExecuteError` into one red line plus exit 1 (backtrace only under `VERBOSE`).

`Dash::Cli::Main` (390 lines) holds the top-level commands and registers ten subcommand classes: `accessory`, `app`, `build`, `lock`, `proxy`, `prune`, `report`, `registry`, `secrets`, `server`.

## `Dash::Cli::Base` (617 lines)

Everything every command shares. `exit_on_failure?` is `true`. `dynamic_command_class` is `Dash::Cli::Alias::Command`, which is how a user-defined alias in `deploy.yml` becomes a Thor command.

**Class options** every command inherits: `-v/--verbose`, `-q/--quiet`, `--version`, `-p/--primary`, `-h/--hosts`, `-r/--roles`, `-c/--config_file` (default `config/deploy.yml`), `-d/--destination`, `-H/--skip_hooks`, and the three lock-wait options (`--lock_wait`, `--lock_wait_timeout` default 900, `--lock_wait_interval` default 15).

`#initialize` (46-59) builds the commander on first use (`initialize_commander`, 118-142) and warns once per process about a legacy `.kamal` project directory — `dash migrate` is exempt, because telling an operator to run the command they are running is noise. The flag lives on the class (`legacy_project_directory_warned`), not the commander, because an alias resets `DASH` and re-enters `Main.start`.

### Locks

`#modify(lock:, server_lock:)` (262-268) is the single entry point: **deploy lock outside, server lock inside**, every caller in that order, so no cycle forms. Both are re-entrant — `with_lock` and `with_server_lock` yield straight through when the process already holds one.

`acquire_server_lock_now` (309-374) takes hosts **one at a time** and rolls back the ones it won on contention. Taking them in one `on(hosts)` sweep would leave the won locks in place and every retry would collide with itself until the timeout. A non-`LockHeldError` failure mid-sweep also rolls back, because `holding_server_lock?` is still false and `with_server_lock`'s `ensure` would never run. `roll_back_server_lock` (379-383) never raises: on the contention path a raise would abandon the locks it was releasing, and on the failure path it would replace the error the operator needs. It always waits rather than failing, since the guarded work is short.

`release_server_lock_on` (399-411) attempts **every** host even after one fails — stopping early would strand the rest with nobody to release them — and re-raises the first error afterwards.

`acquire_lock_with_wait` (467-501) refuses to wait on a lock whose details do not contain `AUTOMATIC_DEPLOY_LOCK_MESSAGE`: a lock a human took by hand is not something to queue behind.

`ensure_run_directory` (583-592) runs `Dash::Commands::Server#ensure_run_directory` only on hosts this process has not swept yet (`DASH.run_directory_ensured_on`), because the deploy lock and the server lock were each paying for it.

### Hooks

`run_hook` (63-95) is public via `no_commands` so collaborators like `Dash::Cli::App::Boot` can fire hooks, but it is not a Thor command. It is serialised behind `HOOK_MUTEX` — hooks set process-global state (the hook env and the SSHKit verbosity) and some fire from inside SSHKit's per-host threads. Verbosity resolution: a CLI flag wins (`-q` hides all, `-v` shows all); otherwise `hooks_output:` in the config forces `:debug` or `:error`. A failed hook becomes `HookError`.

`pre_connect_if_required` (547-552) is called from the overridden `#on`, so the `pre-connect` hook fires once, lazily, before the first remote command.

### Reporting

See [../reports/summary.md](../reports/summary.md). The methods live here: `print_runtime`, `finish_report`, `report_run`, `report_trends`, `write_report`, `report_hook_details`, `record_startup_timing`, `analyze_report`, `guarded_report`, `timed`.

## `Dash::Cli::Main`

`deploy` (21-71) is the reference sequence. Each step is wrapped in `timed(...)`, which is what fills the phase table:

1. `print_config_banner` — service, destination, abbreviated version, each role's hosts and `readiness_description` (yellow when the source is `:none`), the proxy hosts, the loadbalancer and why it is on, and the three timeouts.
2. `Validate config and secrets`
3. `Pull app image` (with `--skip_push`) or `Build and push app image` — the yielded timing entry becomes `DASH.report.build_entry`
4. `analyze_report` — **before** the boot, so the advice still prints when a boot fails
5. under the deploy lock: `pre-deploy` hook, `Ensure dash-proxy`, `Boot accessories` (setup only), `Detect stale containers`, `Boot`, `Loadbalancer` (when `load_balancing?`), `Prune`
6. outside `print_runtime`: the `post-deploy` hook, with `runtime` and `report_hook_details`

`setup` wraps `deploy(boot_accessories: true)` after bootstrapping servers; `redeploy` is `deploy` without the bootstrap, proxy boot, accessories and prune. `rollback` boots a named version, but only after `container_available?` (329-347) confirms every role on every app host has a container for it.

Other commands: `details`, `audit`, `config` (redacted YAML), `docs [SECTION]` (prints the commented-YAML doc files), `doctor`, `init`, `remove`, `migrate`, `upgrade`, `version`.

`init` (199-241) resolves the project directory rather than hardcoding `.dash`: a project still on `.kamal` must get its stubs there, or `init` would create a second directory that silently wins resolution and orphans the operator's real secrets.

## `dash doctor` (`lib/dash/cli/doctor*`)

Readiness checks split across `config_checks.rb`, `host_checks.rb` and `endpoint_checks.rb`. It runs before any clone exists, so its Dockerfile row reads the **working tree** and prints the path it read; the deploy's own advice reads the actual build directory. `doctor` exits non-zero with `Dash::Cli::DoctorError` naming every failing check, and says how many warnings there are when it passes.

## `dash build` (`lib/dash/cli/build.rb`, 305 lines)

`deliver` = `push` + `pull`. `push` attaches a `Dash::Build::ProgressParser` as the SSHKit interaction handler unless the builder is `pack?`, then calls `record_build_report` (184-201) — which runs **whether the build succeeded or failed**, because a partial report naming the step that broke is exactly what an operator wants. Nothing in it may raise: it is entirely inside `guarded_report`.

Standalone (`dash build push` outside a deploy, e.g. a CI pipeline that splits build from deploy), `record_build_report` also prints the build block and runs the analysis itself, because there is no phase table to sit under and no deploy coming. `dev` passes `build_directory: "."` so it analyses the working directory it actually built, rather than a clone it never made.

## `dash proxy` (`lib/dash/cli/proxy.rb`, 728 lines)

The largest CLI file: `boot`, `boot_config`, `reboot`, `upgrade`, `start`, `stop`, `restart`, `details`, `logs`, `remove`, `loadbalancer`, `cache`, `domains`, `export_certs`, `import_certs`, and three hidden `remove_*` commands. Collaborators under `lib/dash/cli/proxy/` carry the multi-step flows: `reboot.rb`, `loadbalancer_reboot.rb`, `loadbalancer_claim.rb`, `legacy_rename.rb`, `drift.rb`.

`boot`, `reboot`, `start`, `stop`, `restart`, `remove`, `export_certs`, `import_certs` and the three hidden `remove_*` commands all take `modify(lock: true, server_lock: true)` — the proxy container is one per host and shared by every destination deployed there. The read-only commands (`details`, `logs`, `cache`, `domains`) take neither, and two mutating ones do not either: the deprecated `boot_config set` and `upgrade`, which asks the operator to confirm instead.

Certificates (`export_certs`, 537-567; `import_certs`, 575-611) move private key material, so both are wrapped end to end:

- `export_certs` runs under the locks for the whole export, because a concurrent deploy could reboot the proxy mid-read and the offline path would archive a torn store. A **running** proxy exports through the container's RPC socket under the proxy's own certificate write lock; a stopped one is read offline by a one-off container. The `download!` is inside a `begin`/`ensure` whose `ensure` removes the host archive, so it cannot outlive a failed download.
- `import_certs` refuses to run against a live proxy (unless `--verify`, which only reads), and its `upload!` is inside the same `ensure` that removes the staged source — a failed or partial upload must not leave certificate material on the host.

## Invariants

- Deploy lock outside, server lock inside — every caller.
- A lock this process took is released on every exit path, including a failure mid-sweep.
- Nothing in the report lifecycle raises out of a command.
- CLI code never builds a docker argument string; it splats what `Dash::Commands::*` returned.

## Related

- [../commands/summary.md](../commands/summary.md), [../configuration/summary.md](../configuration/summary.md), [../reports/summary.md](../reports/summary.md)
- [../review/cli-and-proxy.md](../review/cli-and-proxy.md)
