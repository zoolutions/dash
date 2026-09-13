# Configuration: `deploy.yml` into objects

`Dash::Configuration` (684 lines) is the bottom of the layer cake. It loads YAML, validates it against the shipped documentation, and eager-builds one object per top-level key. Everything above it reads objects, never the raw hash.

## Loading

`create_from(config_file:, destination:, version:)` sets `DASH_DESTINATION`/`KAMAL_DESTINATION`, then deep-merges `config/deploy.yml` with `config/deploy.<destination>.yml` when a destination is given. Each file is read as ERB first and then YAML (`unsafe_load` where available, so aliases still work), and a missing file raises.

`#initialize` (57-…) validates the whole raw hash and then eager-loads every section in dependency order — `servers` and `registry` first, then accessories, aliases, boot, builder, env, logging, output, report, proxy, and the rest. Eager, because construction **is** validation: a `deploy.yml` mistake should be a sentence before the first SSH connection, not an exception halfway through a boot.

## Validation

`Dash::Configuration::Validation` is a concern each section includes. `validation_doc` reads `lib/dash/configuration/docs/<section>.yml` — **15** commented-YAML files, the same ones `dash docs` prints — and `Dash::Configuration::Validator` walks the operator's config against that example, checking types key by key and rejecting unknown keys. Nine sections have a `Validator` subclass under `lib/dash/configuration/validator/` for semantics the example cannot express: `accessory`, `alias`, `builder`, `configuration`, `env`, `proxy`, `registry`, `role`, `servers`.

So the docs are load-bearing twice over: they are what `dash docs` prints, what the validator checks against, and (through `docs/app/models/config_doc.rb`) what the documentation site's Configuration pages are generated from.

`Dash::Configuration::Validator::Proxy` (736 lines) carries most of the semantic checks, because dash-proxy only logs a warning for something it does not recognise and then carries on without it — the symptom of a typo is a feature silently missing, so the check has to happen here. `validate_dns_provider_zones!` (161-181) is the pattern: the hash form of `acme: dns_provider:` maps zones to providers, the wire format is repeatable `zone=provider` entries **cut at the first `=`**, so a zone key containing `=` is rejected by name rather than silently building a different entry; a zone must be a non-empty string with no whitespace; and each provider must be one of the 21 names in `Proxy::Acme::SUPPORTED_DNS_PROVIDERS` (10 canonical `DNS_PROVIDERS` plus 11 `DNS_PROVIDER_ALIASES` that dash-proxy accepts but does not advertise, and which therefore cannot be generated from `--help` or drift-checked).

## `report:` (`lib/dash/configuration/report.rb`, 65 lines)

Every key is optional and the defaults are what an operator who has never heard of the block gets: the table prints, the advice under it prints, and hadolint joins in only if it is already installed.

| Key | Default | Meaning |
|---|---|---|
| `advice` | `true` | run the Dockerfile and trend rules at all |
| `hadolint` | `"auto"` | `auto`/`true` = run it when on `PATH`; `false` = never |
| `history` | `20` | how many reports to keep per destination; `0` turns saving off |
| `ignore` | `[]` | rule ids to drop from the advice |

Two of these **raise `Dash::ConfigurationError`** rather than fall back, and they are the exception to "nothing about the report may fail a command": `hadolint:` set to anything but `auto`/`true`/`false`, and a negative `history:`. Both are typos that would otherwise read as "off" — the operator would lose findings, or stop saving the reports they were in the middle of configuring, and never learn why. `history: 0` is an explicit, supported disablement and is not a typo.

## The proxy

`Dash::Configuration::Proxy` (671 lines) holds the identity constants (`CONTAINER_NAME`, `NETWORK`, `CONFIG_VOLUME`, `IMAGE_TITLE`, their `LEGACY_*` twins, `LEGACY_RENAME_MARKER`) and the loadbalancer decision.

`effective_loadbalancer` (243-251) resolves in order: nothing unless the config is load-balanced at all; `false` when `loadbalancer: false`; the primary role's first host when `loadbalancer: true`; the named host when one is given; the primary role's first host when `auto_load_balanced_primary_role?`. **The last branch is the auto-activation**: a primary role with more than one web host turns the loadbalancer on without anyone writing it down, which is why multi-host test fixtures that are not testing it must set `loadbalancer: false` (`.claude/rules/testing.md`) and why `Dash::Cli::Main#print_config_banner` prints the reason when the key is absent.

`Dash::Configuration::Proxy::Run` (341 lines) materialises the `dash-proxy run` invocation. `MINIMUM_VERSION` (`v1.1.0.1`) is the image tag the gem requires; `Rakefile`'s release task refuses to release while it is not pullable from `ghcr.io/zoolutions/dash-proxy`, and `bin/sync-proxy-flags` regenerates `test/fixtures/kamal_proxy_flags.yml` from the image so `test/proxy_flag_coverage_test.rb` catches drift between the gem's `deploy.yml` surface and the proxy's actual flags.

`config_digest` (41-43) hashes `DIGEST_SCHEMA_VERSION`, the image, the run command, the docker options and the **secret names** — names, not values, because the digest is published as a docker label and hashing secret material into a world-readable label buys an offline guessing target for nothing. `--env-file` names a path rather than the variables inside it, so without the names a swapped credential would leave the digest unmoved and the old proxy running; rotating a value still needs an explicit `dash proxy reboot`.

`Proxy::Acme#run_command_args` renders with `=` rather than a space, because Cobra only reads a boolean flag's value in `--flag=false` form — `--acme-http-fallback false` would set the flag true and leave `false` behind as a stray argument.

## Secrets

`Dash::Secrets` reads `<project directory>/secrets`, `secrets-common` and `secrets.<destination>`, with `Dash::Secrets::Adapters` (**11** files, 10 adapters plus `base.rb`) covering 1Password, LastPass, Bitwarden, Bitwarden Secrets Manager, Doppler, Enpass, Passbolt, AWS Secrets Manager, GCP Secret Manager, and a `test` adapter. Each adapter shells out through `Base`'s backtick helper, which is what `SecretAdapterTestCase#stub_ticks` stubs.

`Dash::Utils.redacted` and `Dash::Utils::Sensitive` keep resolved values out of `dash config` output and the audit log.

## Invariants

- Construction validates. A bad `deploy.yml` fails before the first connection.
- The `docs/*.yml` files are the validator's example, `dash docs`' output and the docs site's source. A new key needs a line there or the validator rejects it as unknown.
- A misspelled `report:` value raises rather than reading as "off".
- Proxy-identity strings are constants, never literals in a builder.

## Related

- [../commands/summary.md](../commands/summary.md), [../docs-site/summary.md](../docs-site/summary.md)
- [../review/config-and-secrets.md](../review/config-and-secrets.md)
