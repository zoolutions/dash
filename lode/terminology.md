# Terminology

The words this repository uses, with the meaning the code gives them.

## The deploy

- **destination** — the `-d`/`--destination` suffix that picks up `config/deploy.<destination>.yml` on top of `config/deploy.yml` (`Dash::Configuration.load_raw_config`). It scopes the deploy lock, the report history and the report filenames; it does **not** scope the proxy, which one host runs once for every destination deployed onto it.
- **deploy lock** — a `mkdir` lock on the primary host, scoped to service + destination so two destinations can deploy at once (`Dash::Commands::Lock::SCOPES`, line 10). Taken outside the server lock, always in that order, so no cycle forms (`Dash::Cli::Base#modify`, lines 262-268).
- **server lock** — a second lock (`Dash::Commander#server_lock`, `scope: :server`) taken on the proxy hosts — or on every host when the config declares none (`Dash::Cli::Base#server_lock_hosts`, lines 413-415) — because the proxy container is shared across destinations while the deploy lock is not (`Dash::Cli::Base`, lines 281-284). Hosts are taken one at a time and rolled back on contention, so a retry does not collide with the locks it already won.
- **hook** — an executable under `<project directory>/hooks/`, run locally with `DASH_*`/`KAMAL_*` details in the environment (`Dash::Cli::Base#run_hook`). Serialised behind `HOOK_MUTEX` because hooks set process-global state and some fire from SSHKit's per-host threads.
- **alias** — a user-defined command name in `deploy.yml`, dispatched through Thor's dynamic command (`Dash::Cli::Alias::Command`); it resets the `DASH` singleton and re-enters `Dash::Cli::Main.start`.
- **accessory** — a supporting container (db, redis, search) described under `accessories:`.
- **project directory** — where the operator's own dash files live in their repo: `.dash`, falling back to `.kamal` while that is the only one present (`Dash::ProjectDirectory`). Deliberately not memoized, because `dash migrate` moves it mid-process.
- **run directory** — the same-named directory on the *server*, holding locks, proxy state and app config. Created by `Dash::Commands::Base#ensure_run_directory`, which also performs the one-shot `.kamal` → `.dash` rename.
- **bridge / legacy rename marker** — the guarded command every container-creating proxy path runs first, renaming pre-rename container, network and volume identities and dropping `.legacy-renamed` so the sweep is a no-op afterwards (`Dash::Configuration::Proxy::LEGACY_RENAME_MARKER`).

## Readiness

- **readiness source** — how a role's readiness is decided. Five values, in the order `Dash::Configuration::Role#readiness_source` (lines 132-144) tries them: `:proxy`, `:healthcheck_exec`, `:healthcheck`, `:docker_options`, `:none`. `#readiness_description` renders each for the deploy banner and `dash doctor`; `#readiness_gated?` is a different question — whether the operator made a decision at all, `healthcheck: false` included.
- **READY_STATUSES** — the two statuses a boot accepts: `"healthy"` and `"no-healthcheck:running"` (`Dash::Commands::Base::READY_STATUSES`). The host-side wait stops on exactly these and the poller accepts exactly these; the pair has to agree.
- **healthcheck drift** — a role declares a healthcheck and the container reports none, meaning the flags never reached `docker run`. Raised as `Dash::Cli::Healthcheck::DriftError` rather than accepted (`Poller#ensure_no_healthcheck_drift`).

## Measurement

- **phase / entry** — one timed region of a run, recorded in start order with a depth, so a parent (`Boot`) prints above the per-host rows it wraps (`Dash::Timings`).
- **round trip / attribution** — a command or an SSH connect stamped onto whatever `Dash::Timings` entry is current on that thread. `lib/dash/sshkit_with_ext.rb` does the stamping; nothing extra is executed to measure it.
- **subtree total** — the command counts the table prints: each entry's own counters rolled up through its ancestors at render time, not at record time (`Timings#subtree_totals`, lines 174-193). They nest, so a consumer must not sum them across depths.
- **vertex / step** — a unit of work buildx reports on. A **dockerfile step** is one that carries an ordinal (`[build 5/9]`); everything else is BuildKit's own bookkeeping and is kept in `steps` but never counted as the operator's (`Dash::Build::Step#dockerfile_step?`).
- **finding** — one piece of advice: `rule`, `severity` (`:warn` or `:info`), `location`, `message`, `suggestion` (`Dash::Dockerfile::Finding`). `rule` is a public string an operator puts in `report: ignore:`, so renaming a rule class renames a config value.
- **advice** — the findings printed under the phase table and saved with the report. Produced by the Dockerfile rules and by the trend rules, which share the `Finding` struct.
- **trend rule** — a finding derived from the saved history rather than from this run: `trend-build`, `trend-boot`, `trend-total`, `trend-overhead` (`Dash::Report::Trends`).
- **schema 1** — the version stamped into every saved report (`Dash::Report::SCHEMA`). A reader that does not recognise the number skips the file rather than guessing.

## Dockerfile analysis

- **shipped stage** — the last stage plus everything it transitively builds `FROM`. A stage reached only through `COPY --from=` contributes files, not layers, so advice about it would be about an image nobody runs (`Dash::Dockerfile::Stage`, lines 1-6).
- **named stage** — one with an explicit `AS` alias. `stage-N` labels are dash's own and are never inheritable (`Stage#named?`).
- **broad copy** — a `COPY`/`ADD` whose source is `.`, `./`, `*` or `/` and which carries no `--from` (`Context::BROAD_SOURCES`, `Context#broad_copy?`).
- **dependency install** — a `RUN` matching one of the twelve package-manager patterns in `Context::DEPENDENCY_INSTALLS`, each paired with the cache directory that manager conventionally wants mounted. apt is separate (`Context::APT_INSTALL`) because its options may come before or after the verb.
- **measured rule** — one that says nothing without a build report: `context-size`, `cache-export-cost`, `uncached-install`. Other rules quote build numbers when there is a build and still fire without one.

## Release

- **MINIMUM_VERSION** — the dash-proxy image tag the gem requires (`Dash::Configuration::Proxy::Run::MINIMUM_VERSION`, currently `v1.1.0.1`). Assertions interpolate it; they never hardcode a tag.
- **config digest** — the label `org.dash.proxy-config-digest` stamped on the proxy container from its run command, so the next deploy can tell a configuration change from a no-op reboot.
