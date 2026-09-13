# Review rules: the CLI, the boot wait, and the proxy bridge

Accepted findings about `lib/dash/cli/`, `lib/dash/commands/app.rb`, `lib/dash/commands/proxy.rb`, `loadbalancer.rb` and `proxy/cert_transfer.rb`. The subsystems are [../cli/summary.md](../cli/summary.md) and [../commands/summary.md](../commands/summary.md).

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### Absence of a container is only ever concluded from a listing that succeeded
- **Holds because:** `! docker container inspect name >/dev/null 2>&1` exits non-zero both for "no such container" and for "the daemon could not be asked" — busy, permission denied, socket gone — so it reads a transient failure as confirmed absence. In the legacy-rename bridge that meant writing `.legacy-renamed` with the legacy container still running, and every later deploy skipping the migration permanently. A **listing** exits 0 whether or not anything matched and non-zero only on a genuine failure, and `result=$(list)` carries the listing's own status (POSIX, verified against sh and bash), so the chain stops before the test runs.
- **Where:** `lib/dash/commands/base.rb#confirmed_empty?` (lines 51-53), used from `lib/dash/commands/proxy.rb` and `loadbalancer.rb`
- **Safe direction:** an unreadable docker state means "not yet migrated" — the bridge runs again, which is a no-op if it already happened. Its argument must be a listing, never an inspect.
- **Origin:** PR #167

### The readiness wait fails the command when the status cannot be read at all, and waits out everything else
- **Holds because:** `2>/dev/null` plus an ignored exit status turns an unreachable daemon or a vanished container into an empty status the loop waits out for the whole `deploy_timeout`, and then blames the container. The inspect no longer redirects its stderr and ends in `|| exit $?`, so docker's own complaint reaches SSHKit's exception. Reaching the deadline exits 0 — that is an answer the poller phrases.
- **Where:** `lib/dash/commands/app.rb#wait_for_ready` (lines 74-86), `#readiness_probe` (lines 161-168)
- **Proven by:** `test/commands/app_test.rb:109` ("wait for ready fails the command when the status cannot be read"), `:97`
- **Origin:** cubic learning 6a68ff83; PR #166

### The probe checks for an **empty** status as well as the exit code, because xargs is not portable on empty input
- **Holds because:** the read is a pipeline, so its exit status is xargs'. When `docker container ls` fails it pipes nothing: GNU xargs runs the utility anyway and exits 123, while BSD and BusyBox skip it and exit 0. Both leave `$status` empty, and empty is not something a working `docker inspect --format` prints — so emptiness is the portable signal. (The GNU behaviour was verified by running the generated command inside `debian:stable-slim` against a fake docker.) An `exec:` probe is the exception: a non-zero exit **is** the answer "not ready", so its output is discarded and the loop continues.
- **Where:** `lib/dash/commands/app.rb#readiness_probe` (lines 161-168)
- **Proven by:** `test/commands/app_test.rb:109`
- **Origin:** PR #166

### The host-side wait writes progress to stderr and the final status to stdout, and the reporter reads stderr only
- **Holds because:** stdout and stderr are separate SSH streams whose chunks can interleave. Folding both into one buffer lets the final status land inside a half-arrived progress line and corrupts them both. The stream split is part of the wait's contract — the loop uses `1>&2` precisely so the capture's stdout is only ever the final status — so the reporter asserts it (`return unless stream_name == :stderr`) instead of leaving a line regex to infer it.
- **Where:** `lib/dash/cli/healthcheck/progress_reporter.rb#on_data`; `lib/dash/commands/app.rb#wait_for_ready`
- **Proven by:** `test/cli/healthcheck/progress_reporter_test.rb:40` ("the final status on stdout never lands in the middle of a progress line")
- **Origin:** PR #166

### The whole certificate export runs under the deploy **and** server locks
- **Holds because:** a concurrent deploy can boot or reboot the proxy mid-export, and the offline read would then archive a torn store. The lock covers the export from the container-running check through the download, not just the read. The same `modify(lock: true, server_lock: true)` wraps `import_certs`, which also refuses to run against a live proxy unless `--verify` (which only reads).
- **Where:** `lib/dash/cli/proxy.rb#export_certs` (lines 537-567), `#import_certs` (lines 575-611)
- **Origin:** cubic learning bbe7b437

### Certificate material never outlives the command that put it on the host
- **Holds because:** the export archive holds private keys. `download!` sits inside a `begin`/`ensure` whose `ensure` runs `remove_certs_archive`, so a failed or partial download still cleans up; on the import side `upload!` is inside the same `ensure` as the `import_certs` capture, so a failed or partial upload leaves nothing behind either.
- **Where:** `lib/dash/cli/proxy.rb#export_certs`, `#import_certs`
- **Origin:** cubic learnings 4802b572, f35a3df7

### The nested `sh -c` import payload is built with `Base#shell`
- **Holds because:** the archive is imported by a one-off container running `sh -c '…'`, and an apostrophe in an operator-supplied `--resolver` name would end the quoting and run whatever followed. `shell` single-quotes the payload and escapes embedded apostrophes (`gsub("'", "'\\''")`).
- **Where:** `lib/dash/commands/proxy/cert_transfer.rb#import_certs`; `lib/dash/commands/base.rb#shell`
- **Origin:** cubic learning 45d28882

### A best-effort `|| true` is parenthesised before it is composed with anything
- **Holds because:** `&&` and `||` bind equally and associate left, so `audit && clean || true && pull` lets a **failed audit** fall into the same `|| true` and pull anyway, with exit status 0 — so `execute` never raises either. Verified in a shell. `combine [ "(", *any(clean, [ :true ]), ")" ], pull` confines the `|| true` to the clean. The group is composed only, never executed on its own: SSHKit's command map prefixes an unknown first word with `/usr/bin/env`, and the first word here is `(`.
- **Where:** `lib/dash/commands/builder/base.rb#clean_then_pull`; `lib/dash/commands/base.rb#group`, `#any`
- **Origin:** PR #159

### The server lock takes hosts one at a time and rolls back what it won
- **Holds because:** taking them in one `on(hosts)` sweep leaves the won locks in place on contention, and every retry then collides with itself until the timeout. A non-`LockHeldError` failure mid-sweep rolls back too, because `holding_server_lock?` is still false and `with_server_lock`'s `ensure` would never run. `roll_back_server_lock` never raises: on the contention path a raise abandons the locks it was releasing, on the failure path it replaces the error the operator needs. `release_server_lock_on` attempts **every** host even after one fails — stopping early strands the rest — and re-raises the first error afterwards.
- **Where:** `lib/dash/cli/base.rb#acquire_server_lock_now` (lines 309-374), `#roll_back_server_lock` (lines 379-383), `#release_server_lock_on` (lines 399-411)
- **Origin:** PR #138

### Not a bug: `Reboot#run` runs the legacy-rename bridge even when `LegacyRename#run` already did
- **Holds because:** in a drifted `dash proxy boot` the guarded bridge command does go out twice per drifted host — one extra round trip. But `Reboot#run` is reachable standalone as `dash proxy reboot`, where nothing else has run the bridge, and that is exactly the bug #168 was: `reboot` created the new container (letting `docker run --volume` create the config volume empty) without the bridge ever running on that host. A `Reboot` that depends on its caller having bridged first is the same bug one refactor later. The command is guarded, so the second run is a no-op.
- **Where:** `lib/dash/cli/proxy/reboot.rb#replace_container`; `lib/dash/cli/proxy/legacy_rename.rb`
- **Origin:** PR #169 (suggestion declined)

### Not a bug: the legacy loadbalancer volume is copied before the old container is stopped
- **Holds because:** every writer into that volume writes atomically — dash-proxy's routing table goes through `writeFileAtomic` (temp file, `fsync`, `os.Rename`), dynamic domains and redirects do temp + rename, the response cache store does `CreateTemp` + rename, and the ACME cache is `autocert.DirCache`. A `cp -a` cannot capture a torn file, so stopping first buys nothing and lengthens the outage.
- **Where:** `lib/dash/cli/proxy/loadbalancer_reboot.rb`
- **Origin:** PR #169 (suggestion declined, with the dash-proxy write paths cited)
