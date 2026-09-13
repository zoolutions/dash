# The docs site (`docs/`)

A self-contained [docs-kit](https://github.com/zoolutions/docs-kit) Rails app inside this repository, with its own `Gemfile`, `bun.lock`, RuboCop and RSpec. It is deployed to https://dash.zoolutions.llc on every published GitHub Release, so the documentation goes live with the gem it documents.

`docs/Gemfile` depends on the gem through `gem "dash", path: ".."`, which is why both `docs-ci.yml` and `docs/Dockerfile` set `BUNDLE_FROZEN: "false"`: bundler 4 defaults to frozen in CI and rejects a path gem whose gemspec is re-evaluated per checkout.

## Pages

Every page is a `DocsUI::Page` subclass under `app/views/docs/pages/`, registered with one `page "…"` line in `app/models/doc.rb`. A page class with no registry line is not routed and not in the nav; the registry also feeds `/llms.txt`, `/llms-full.txt`, search and the MCP surface, and silently skips a page whose view class does not resolve. Scaffold with `bin/rails g docs_kit:page "Title" --group=…`, which writes both halves. The authoring contract — Markdown-first `#content`, single-quoted heredocs, never hand-written HTML — is `docs/AGENTS.md`.

**29** registered pages, in six groups: Getting started, Migrate, Deploying, Proxy, Configuration, Reference.

### Behaviour → page

| Change to | Page |
|---|---|
| a new or changed `deploy.yml` key | the generated Configuration page for that section (below) |
| deploy report: phases, build block, advice, trends, the saved JSON schema | `deploy_report.rb` (slug `deploy-report`) |
| a CLI command's name, options or printed sentences | `commands.rb` |
| hooks and the `DASH_*`/`KAMAL_*` hook environment | `hooks.rb` |
| role readiness, healthchecks, worker roles | `worker_roles.rb` |
| canary / rolling boot groups | `canary_rollout.rb` (slug `rollout`) |
| loadbalancer activation and layering | `load_balancing.rb` |
| certificates, SAN batching, `export_certs` / `import_certs` | `certificates.rb` |
| response caching | `caching.rb` |
| traffic shaping | `traffic_shaping.rb` |
| a secrets adapter | `secrets_adapters.rb` (hand-written, in the Configuration group) |
| anything an operator arriving from kamal would trip over | `from_kamal.rb` |

### The Configuration group is generated

**15** of the Configuration pages are `Views::Docs::Pages::Config::*` classes bound to a slug, rendering `lib/dash/configuration/docs/<slug>.yml` through `app/models/config_doc.rb` — the same commented-YAML files `dash docs` prints and `Dash::Configuration::Validation` validates an operator's config against. So one file is three things at once: the validator's example, the CLI's help, and a published page.

`spec/config_docs_spec.rb` fails in both directions — a doc YAML with no registered page, and a `ConfigPage` pointing at a YAML that does not exist — and also asserts every page binds to its own slug. Hand-written pages in the group (Secrets adapters) are not `ConfigPage`s and the spec skips them. Adding a `deploy.yml` key therefore means: the key in `lib/dash/configuration/`, a line in its `docs/*.yml`, and, for a whole new section, a `page` line plus a `Config::` view class.

## Checks

| Command (run from `docs/`) | What |
|---|---|
| `bin/dev` | `bin/rails server` |
| `bundle exec rake lint` | RuboCop over `app/`, `spec/`, `config/`, `Rakefile`, `config.ru` — passed as an explicit file list, because the repo-root `.rubocop.yml` excludes `docs/**/*` and a bare `rubocop` here would inherit that exclude and lint nothing |
| `bundle exec rspec` | `config_docs_spec.rb` plus three request specs: `docs_spec.rb` (renders every registered page), `ai_surfaces_spec.rb`, `mcp_spec.rb` |
| `bun install && bun run build:css` | Tailwind build |

## CI and deploy

- `docs-ci.yml` runs only on `docs/**` (and its own file) changes, on `main` and on pull requests, with `concurrency: cancel-in-progress`. Steps: lucide icon sync → `bun install && bun run build:css` → `rake lint` → `rspec`, all with `working-directory: docs`.
- `deploy-docs.yml` runs on a published GitHub Release or manually, and delegates to the shared `zoolutions/docs-kit` reusable workflow. `image`/`service` are the repo name (`dash`) so the pushed ghcr package auto-links to this repo and `GITHUB_TOKEN` can push and pull it without a PAT; they must match `service:`/`image:` in `docs/config/deploy.yml` and the `Dockerfile` LABEL. Deploying on release keeps the site's `Dash::VERSION` badge in step with the published gem.
- The docs site is deployed **with dash itself**, which is how the tool documents its own use.

## Related

- [../configuration/summary.md](../configuration/summary.md) — the `docs/*.yml` files on the gem side
- [../reports/summary.md](../reports/summary.md) — what `deploy_report.rb` describes
- [../review/docs-and-release.md](../review/docs-and-release.md)
