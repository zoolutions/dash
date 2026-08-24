# Upstream Sync — Retired (Historical Note)

**There is no upstream sync anymore.** As of the 2026-08 clean break (zoolutions/dash#115),
dash left the basecamp/kamal fork network, the `upstream` remote was removed, and the old
`dash` integration branch was fast-forwarded into `main` and deleted. `main` is the only
long-lived branch; everything lands there via PR. The upstream-owned duplicate files
(`kamal.gemspec`, `bin/release`, `bin/kamal`) were deleted; `bin/release-dash` was replaced
by `rake release[X.Y.Z]` + trusted publishing (`.github/workflows/release.yml`).

If a basecamp/kamal fix is ever wanted, cherry-pick it deliberately from a fresh clone of
their repo — do not re-add an `upstream` remote or resurrect the mirror-branch model.
Nothing is upstreamed to basecamp anymore; the "safe moat" list in `ROADMAP.md` is moot.

What survives from the fork era:

- **Release ordering**: proxy image first, gem second. `MINIMUM_VERSION`
  (`lib/kamal/configuration/proxy/run.rb`) must name a published, public
  `ghcr.io/zoolutions/dash-proxy` tag before the gem releases. `rake release` gates on this.
- **Tag hygiene**: never `-suffix` tags (Gem::Version prerelease trap), never `git push --tags`.
  Gem tags are now plain `vX.Y.Z`; old `dash-v*` tags are frozen history.
- **Server-artifact names**: the `kamal-proxy` container name, image title label
  `org.opencontainers.image.title=kamal-proxy`, `.kamal/` directory, `KAMAL_*` env vars, and
  the `Kamal::` Ruby namespace remain until the staged renames (namespace, then server
  artifacts with a rolling-upgrade bridge) ship.
- **Test discipline**: interpolate `MINIMUM_VERSION` in assertions; multi-host fixtures set
  `loadbalancer: false` (the dind harness can't resolve inner VM hostnames).
- The old `ghcr.io/zoolutions/kamal-proxy` package stays published — released gem versions
  (< 3.2.0) still pull it.
