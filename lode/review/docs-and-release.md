# Review rules: the docs site and release mechanics

Accepted findings about `docs/` prose and the release path. The site is [../docs-site/summary.md](../docs-site/summary.md); the release flow is [../testing-and-ci/summary.md](../testing-and-ci/summary.md).

**The rule behind all of these:** documentation is a claim about code. A sentence written before a behaviour change is stale after it, and nobody re-reads it unless the diff makes them.

*A rule with no **Proven by** line has no test that pins that specific behaviour — the gap is real, not an omission.*

### A JSON example that points into an array shows the row it points at
- **Holds because:** `build_phase` is an **index** into `phases`, and the schema example elided the very row the index named — so a reader counting rows in the example got a different phase than dash would. The example now shows all three phases with `"build_phase": 1` pointing at the middle one.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`; `lib/dash/report.rb#to_h` (lines 59-65)
- **Origin:** cubic learning 5af29be4; PR #158

### The trend window is described as "three *succeeded* reports of the same command", not "three deploys"
- **Holds because:** `Trends#comparable` filters on `status == "succeeded"` before counting, and counts retained reports — so a destination whose last three deploys failed has no trend at all, which is the opposite of what "after three deploys you get trends" promises.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`; `lib/dash/report/trends.rb#comparable` (lines 43-48)
- **Origin:** PR #158

### `dash report --last` is documented as scoped by destination, not by command
- **Holds because:** `History` narrows on destination only, so `setup`, `redeploy` and `rollback` runs all get a row. Only the trend rules narrow by command, and saying otherwise sends a reader looking for rows that are there.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`; `lib/dash/report/history.rb`
- **Origin:** cubic learning ab926741; PR #158

### The docs say which command frame a report's `status` describes
- **Holds because:** a `post-deploy` hook failure leaves a plain `dash deploy` report `succeeded` and can mark `dash setup`'s deferred outer report `failed`. A reader who has only ever run one of the two would otherwise conclude the report is lying.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`; `lib/dash/cli/base.rb#print_runtime` (lines 146-162)
- **Origin:** cubic learning 1a20463d; PR #158

### "Measured rules" is stated as two different things, because it is
- **Holds because:** every measured rule quotes the build's numbers when there is a build, but only `context-size`, `cache-export-cost` and `uncached-install` fire *exclusively* then. Collapsing the two into one sentence made `dash doctor`'s output look broken.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`; [../dockerfile-advice/summary.md](../dockerfile-advice/summary.md)
- **Origin:** cubic learning b1721a6f; PR #157

### A sample that embeds a version goes stale on the next release, and says so
- **Holds because:** the saved-report example carries `dash_version`, which is a real field of a real file. It was corrected to match `lib/dash/version.rb`, and the correction is not automatable — a note in the page records that it is a sample of a saved file and will drift.
- **Where:** `docs/app/views/docs/pages/deploy_report.rb`
- **Origin:** PR #158

### A gem tag is `vX.Y.Z` with no suffix, and single tags are pushed
- **Holds because:** `Gem::Version` parses `-` as a prerelease, which sorts **older** than the base — so `v1.0.0-rc1` hard-fails `dash proxy boot`'s minimum-version check. `rake release` creates the gem tag through `gh release create`; `git push --tags` is never used.
- **Where:** `Rakefile`, `bin/release`; `.claude/rules/git-workflow.md`
- **Origin:** `.claude/rules/git-workflow.md`, carried forward

### The proxy image is published before the gem, and `rake release` refuses otherwise
- **Holds because:** integration tests and `dash proxy boot` both pull `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION`. Releasing the gem first ships a version that cannot deploy. The release task reads `MINIMUM_VERSION` out of `lib/dash/configuration/proxy/run.rb` and aborts unless `docker buildx imagetools inspect` can see the tag — before anything else runs.
- **Where:** `Rakefile` (lines 36-44)
- **Origin:** `.claude/rules/git-workflow.md`, carried forward; enforced in code

### `docs-ci.yml` unfreezes the bundle on purpose
- **Holds because:** bundler 4 defaults to frozen in CI and rejects `gem "dash", path: ".."`, whose gemspec is re-evaluated per checkout. `BUNDLE_FROZEN: "false"` is set in the workflow and for the same reason in `docs/Dockerfile`; the lockfile still pins every other gem.
- **Where:** `.github/workflows/docs-ci.yml`; `docs/Dockerfile`
- **Origin:** no review thread — recorded from the workflow's own comment, because a bundler upgrade is exactly the moment someone would "tidy" it away
