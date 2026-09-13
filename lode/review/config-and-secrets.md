# Review rules: configuration validation and secrets

Accepted findings about `lib/dash/configuration/` and `lib/dash/secrets/`. The subsystem is [../configuration/summary.md](../configuration/summary.md).

**The safe direction here is the opposite of the report's.** Everywhere else in dash a misunderstanding costs a piece of advice; in `deploy.yml` validation a misunderstanding costs the operator a feature they think they configured. dash-proxy only logs a warning for a flag it does not recognise and then carries on without it, so the symptom of a typo is silence. Validation therefore **raises**, at config time, before the first SSH connection.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### `report: hadolint:` accepts only `auto`, `true` and `false`; anything else raises
- **Holds because:** `hadolint: yes` or `hadolint: "on"` would otherwise fall through to the "off" branch and the operator would quietly lose every hadolint finding, with nothing to tell them why. The one place the report subsystem is allowed to fail a command is here, where the failure is a sentence about a typo and not a broken deploy.
- **Where:** `lib/dash/configuration/report.rb#ensure_valid_hadolint_setting` (lines 52-56)
- **Proven by:** `test/configuration/report_test.rb:29` ("an unknown hadolint setting is rejected rather than silently off")
- **Origin:** cubic learning 44aaf149; PR #157

### A negative `report: history:` raises; `history: 0` does not
- **Holds because:** `history: -1` made every deploy print "Deploy report unavailable" **and** pruned nothing, so the directory grew without bound. A typo-like count must not read as a disablement — but `0` is an explicit, supported disablement and is not a typo, so it turns saving off silently and on purpose.
- **Where:** `lib/dash/configuration/report.rb#ensure_valid_history` (lines 60-64); `lib/dash/report/writer.rb#write` returns nil when `keep.zero?`
- **Proven by:** `test/configuration/report_test.rb:41` ("a negative history is rejected rather than read as off"), `test/report/writer_test.rb:68` ("history: 0 writes nothing at all")
- **Origin:** cubic learning 4cb41a2c; PR #158

### Every ACME DNS zone key is a non-empty string with no whitespace, and `=` is rejected by name
- **Holds because:** the hash form of `acme: dns_provider:` maps zones to providers and the wire format is repeatable `zone=provider` entries **cut at the first `=`**. A zone key containing `=` would silently build a different entry than the one written, so it is rejected by name rather than reinterpreted. The `=` wire-format check stays separate from the shape check, so each says what it means. Each provider must be one of `Proxy::Acme::SUPPORTED_DNS_PROVIDERS` — 10 canonical `DNS_PROVIDERS` plus 11 `DNS_PROVIDER_ALIASES` that dash-proxy accepts but does not advertise, and which therefore cannot be generated from `--help` or drift-checked.
- **Where:** `lib/dash/configuration/validator/proxy.rb#validate_dns_provider_zones!` (lines 161-181); `lib/dash/configuration/proxy/acme.rb::SUPPORTED_DNS_PROVIDERS`
- **Proven by:** `test/configuration/proxy/acme_test.rb`
- **Origin:** cubic learning 1181703b

The invariants this area holds that came out of the code rather than a review thread — the config digest hashing secret *names* only, `--flag=false` for Cobra booleans, a `--hosts` filter that matches nothing raising, `DASH_*` winning over `KAMAL_*` by being *set* — are in [../configuration/summary.md](../configuration/summary.md) and [../commands/summary.md](../commands/summary.md), not repeated here.
