# frozen_string_literal: true

# The migration story: switching an existing kamal 2.x deployment to dash.
class Views::Docs::Pages::FromKamal < DocsUI::Page
  title "From kamal"
  eyebrow "Migrate"

  def lead = "Swap the gem, keep the config — existing kamal deployments upgrade in place."

  def content
    the_short_version
    what_stays
    the_proxy
    behavior_changes
    step_by_step
  end

  private

  def the_short_version
    DocsUI::Section("The short version") do
      md <<~'MD'
        dash began as a fork of [basecamp/kamal](https://github.com/basecamp/kamal)
        and made a clean break in 2026 — it ships the proxy features upstream
        wouldn't merge and versions independently (the 3.x line). Migration is
        deliberately boring:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        gem uninstall kamal
        gem install dash        # or: swap `gem "kamal"` for `gem "dash"` in your Gemfile
        dash deploy
      SHELL
      md <<~'MD'
        The executable is `dash` instead of `kamal` — update CI pipelines and
        scripts that call the CLI by name. Everything else is designed to keep
        working.
      MD
    end
  end

  def what_stays
    DocsUI::Section("What stays exactly the same") do
      DocsUI::Table(
        [ "Artifact", "Status" ],
        [
          [ [ :code, "config/deploy.yml" ], [ :md, "Unchanged — dash's config is a superset of kamal 2.x; every dash-only key is optional." ] ],
          [ [ :code, ".kamal/secrets" ], [ :md, "Unchanged — same location, same dotenv format." ] ],
          [ [ :md, "`.kamal/` on the servers" ], [ :md, "Unchanged — locks, audit log, and hooks live where they always did." ] ],
          [ [ :md, "`kamal-proxy` container" ], [ :md, "Same container name; dash manages the one kamal booted." ] ],
          [ [ :md, "`KAMAL_*` env vars & secrets" ], [ :md, "Unchanged — `KAMAL_REGISTRY_PASSWORD` and friends keep their names." ] ],
          [ [ :md, "Hooks (`.kamal/hooks/`)" ], [ :md, "Unchanged — same hook names, same environment." ] ]
        ]
      )
      md <<~'MD'
        There is nothing to migrate on the servers — a host deployed with kamal
        is a host dash can deploy to.
      MD
    end
  end

  def the_proxy
    DocsUI::Section("The proxy switches image, not identity") do
      md <<~'MD'
        dash uses its own proxy build,
        [dash-proxy](https://github.com/zoolutions/dash-proxy)
        (`ghcr.io/zoolutions/dash-proxy`) — a superset of kamal-proxy that adds
        load balancing, SAN batching, wildcard certs, caching, and traffic
        shaping. The container keeps the `kamal-proxy` name.

        dash reads the running proxy's version from its image tag and compares
        it with the minimum version this gem requires. On your first
        `dash deploy`, the drift is detected and the proxy is rebooted
        automatically — one host at a time — onto the dash-proxy image
        ([details](/docs/proxy)). Set `proxy: reboot_on_deploy: false` to opt
        out; dash then warns and leaves the proxy alone until you run
        `dash proxy reboot` yourself.
      MD
      DocsUI::Callout(:note) do
        plain "A proxy reboot restarts the proxy container. Without "
        code { "run/port_holder" }
        plain " enabled there is a brief window while the new container binds the ports — schedule the first deploy accordingly."
      end
    end
  end

  def behavior_changes
    DocsUI::Section("Behavior changes to review") do
      md <<~'MD'
        - **Load balancing auto-activates for multi-host primary roles.** When
          your primary (web) role has more than one host, dash fronts the fleet
          with a [load balancer](/docs/load-balancing) on the first web host.
          Kamal instead expects you to bring your own. Opt out with
          `proxy: loadbalancer: false` if you already have external load
          balancing.
        - **`dash doctor` gates readiness.** New diagnostic command — run it
          before the first deploy to check servers, registry, proxy, ports,
          DNS, and certificates.
        - **Version lineage.** dash releases its own 3.x line; kamal version
          pins in scripts or Gemfiles don't translate. `dash upgrade` still
          exists for legacy Kamal 1.x → 2.0 server layouts.
      MD
    end
  end

  def step_by_step
    DocsUI::Section("Step by step") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        # 1. Swap the gem
        bundle remove kamal && bundle add dash && bundle binstubs dash

        # 2. Sanity-check the config parses and the servers are ready
        dash config
        dash doctor

        # 3. Deploy — reboots the proxy onto dash-proxy, then ships the app
        dash deploy
      SHELL
      md <<~'MD'
        Upstream kamal's docs at [kamal-deploy.org](https://kamal-deploy.org)
        still cover the shared basics; the [Configuration](/docs/configuration)
        reference here is generated from the dash gem itself and includes every
        dash-only key.
      MD
    end
  end
end
