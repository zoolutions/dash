# Upstream Sync Rules

Branch roles: `main` mirrors basecamp/kamal (fast-forward only, never commit). `dash` is the integration + release branch — fork identity plus merged features. Feature branches (`feat/*`) always root off `dash` and merge `dash` forward — never off `main`, never rebase published branches. `git rerere` is enabled, so previously-seen conflicts auto-replay their resolutions.

Upstream only ever reaches a feature branch through `dash`: `upstream/main` → `main` → `dash` → `feat/*`. A feature branch never merges `main` directly.

## Routine sync

```bash
git fetch upstream --tags --prune
git checkout main && git merge --ff-only upstream/main && git push origin main

git checkout dash && git merge main
bundle install                    # settle Gemfile.lock
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
bundle exec rubocop --parallel
git push origin dash

# per feature branch — merge dash forward, never main:
git checkout feat/loadbalancing && git merge dash && <tests> && git push
git checkout dash && git merge feat/loadbalancing && <tests> && git push
```

## Conflict playbook

| File | Resolution |
|---|---|
| `lib/kamal/version.rb` | take upstream's — the fork version is only ever written by `bin/release-dash` at release time |
| `Gemfile.lock` | take either side, run `bundle install`, commit the result |
| `lib/kamal/configuration/proxy/run.rb` (`MINIMUM_VERSION`) | upstream bumped their proxy: release the proxy fork first (`v<new-base>.1`), then set that tag here |
| `lib/kamal/configuration/proxy/run.rb` (repository) / `boot.rb` (`repository_name`) | keep `ghcr.io/mhenrixon` |
| `test/cli/proxy_test.rb`, `test/commands/proxy_test.rb` | keep the ghcr org and the `#{...MINIMUM_VERSION}` interpolation; adopt upstream's new assertions around them |
| `test/integration/docker/deployer/setup.sh` | keep the ghcr image; its tag must equal `MINIMUM_VERSION` |
| `dash.gemspec` | never conflicts (fork-owned) — but run `diff kamal.gemspec dash.gemspec` after every sync and mirror upstream dependency changes by hand |
| `.github/workflows/ci.yml` | keep the `dash` entry under push branches |
| new upstream multi-host integration fixtures | add `loadbalancer: false` under `proxy:` — the fork auto-activates the loadbalancer for any primary role with >1 host, which the dind harness cannot support (vm hostnames don't resolve inside the inner docker network) |

## Release procedure

Order is a hard constraint: **proxy image first, gem second** — integration tests and `kamal proxy boot` pull `ghcr.io/mhenrixon/kamal-proxy:$MINIMUM_VERSION`.

```bash
# 1. ../kamal-proxy, on dash (only when MINIMUM_VERSION moves or proxy features changed):
script/release-dash v0.9.2.1
docker buildx imagetools inspect ghcr.io/mhenrixon/kamal-proxy:v0.9.2.1   # amd64+arm64 present

# 2. this repo, on dash:
#    ensure Kamal::Configuration::Proxy::Run::MINIMUM_VERSION == that tag
bin/test                          # full suite incl. integration
bin/release-dash 2.12.0.1         # version.rb + Gemfile.lock, tag dash-v2.12.0.1, gem push dash
```

Tag grammar: gem tags `dash-v<upstream>.<n>`, proxy image tags `v<upstream-base>.<n>`. Gem versions are four-segment `<upstream>.<n>` — `Gem::Version` sorts them above the upstream base and below its next release. Never `-suffix` tags: Gem::Version treats `-` as a prerelease marker that sorts BELOW the base and breaks the proxy minimum-version check.

## Upstreaming a feature

Feature branches root off `dash`, so they carry fork identity in their history. Do **not** `merge --squash` one onto `main` — that would drag all of `dash` into the PR. Extract the feature's own diff instead:

```bash
git checkout -b pr/<feature> main
git diff dash...feat/<feature> | git apply -3      # the feature's changes only
git status                                         # review before committing
git commit -a -m "<upstream-facing message>"
```

The three-dot `dash...feat/<feature>` diffs from `merge-base(dash, feat/<feature>)` to the branch tip. The merge-base is a commit on `dash`, so everything `dash` already had — fork identity, the `.claude/` toolkit, other merged features — falls out of the diff, and any `git merge dash` the branch did along the way is excluded too. What is left is exactly the feature.

`git apply -3` may conflict where the feature touches a file that differs between `main` and `dash` (proxy defaults, `MINIMUM_VERSION`, test fixtures). Resolve toward upstream's shape — the PR must read as if written against `main`.

Hand-clean the diff before opening the PR against basecamp/kamal (e.g. drop the unrelated `lib/kamal/cli/build.rb` login change bundled in feat/loadbalancing), and confirm no fork-owned file (`dash.gemspec`, `bin/release-dash`, `CLAUDE.md`, `.claude/`) is present.

Rejected-by-basecamp features (see `ROADMAP.md`'s "safe moat" list) are never upstreamed — skip this entirely for them.

## Never

- commit to `main` or rebase published branches
- `git push --tags` — single-tag pushes only (`git push origin tag dash-v2.12.0.1`)
- release the gem while `MINIMUM_VERSION` names an unpublished proxy tag
- edit `kamal.gemspec`, `bin/release`, or other upstream-owned files
