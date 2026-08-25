# frozen_string_literal: true

# What dash is, where it came from, and what it adds over upstream kamal.
class Views::Docs::Pages::Overview < DocsUI::Page
  title "Overview"
  eyebrow "Getting started"

  def lead = "Deploy web apps in containers to any server running Docker, with zero downtime."

  def content
    what_is_dash
    how_it_works
    beyond_kamal
    where_next
  end

  private

  def what_is_dash
    DocsUI::Section("What is dash?") do
      md <<~'MD'
        dash deploys containerized web apps to your own servers — bare metal,
        cloud VMs, anything you can SSH into that runs Docker. It builds your
        image, pushes it to a registry, pulls it on your hosts, and switches
        traffic to the new containers with **zero downtime**, using
        [dash-proxy](https://github.com/zoolutions/dash-proxy) to swap requests
        between old and new versions seamlessly.

        dash began as a fork of [basecamp/kamal](https://github.com/basecamp/kamal)
        and made a clean break in 2026. It ships the features upstream wouldn't
        merge — proxy load balancing, readiness gates, response caching, traffic
        shaping, SAN certificate batching, wildcard certificates — and moves at
        its own pace. Existing kamal deployments **upgrade in place**: the
        on-server artifacts (the `.kamal/` directory, the `kamal-proxy`
        container) are unchanged, `KAMAL_*` env vars are still set alongside
        their `DASH_*` twins, and a `.kamal/` directory in your repo is still
        read. See [From kamal](/docs/from-kamal) for the migration story.
      MD
    end
  end

  def how_it_works
    DocsUI::Section("How a deploy works") do
      md <<~'MD'
        One command, five steps:

        1. **Build** — `docker build` your app image (locally or on a remote
           builder), tagged with the current git SHA.
        2. **Push** — push the image to your registry, then pull it on every
           server.
        3. **Gate** — acquire the deploy lock and run readiness checks.
        4. **Boot** — start new containers alongside the old ones, wait for the
           healthcheck to pass.
        5. **Switch** — tell the proxy to route traffic to the new containers,
           then stop the old ones. Requests in flight finish on the old version;
           new requests hit the new one.

        Everything is plain SSH + Docker — no control plane, no agents on your
        servers, no lock-in. The entire deployment is described in one file,
        `config/deploy.yml`.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml")
        service: myapp
        image: my-user/myapp

        servers:
          - 192.168.0.1
          - 192.168.0.2

        proxy:
          ssl: true
          host: app.example.com

        registry:
          username: my-user
          password:
            - DASH_REGISTRY_PASSWORD
      YAML
    end
  end

  def beyond_kamal
    DocsUI::Section("Beyond kamal", description: "The proxy features upstream does not have.") do
      DocsUI::Table(
        [ "Feature", "What it gives you" ],
        [
          [ [ :md, "[Load balancing](/docs/load-balancing)" ],
            [ :md, "One host fronts the whole fleet — auto-activates for multi-host roles, shareable between apps." ] ],
          [ [ :md, "[SAN batching & wildcards](/docs/certificates)" ],
            [ :md, "Batch domains onto shared SAN certificates, issue wildcards via DNS-01, learn TLS hostnames from your app at runtime." ] ],
          [ [ :md, "[Response caching](/docs/caching)" ],
            [ :md, "An RFC 9111 shared cache in front of your app, administered with `dash proxy cache`." ] ],
          [ [ :md, "[Traffic shaping](/docs/traffic-shaping)" ],
            [ :md, "Rate limiting, IP allow/deny lists, per-path timeouts, read routing, session affinity, scale to zero." ] ],
          [ [ :md, "Readiness gates" ],
            [ :md, "`dash doctor` diagnoses servers, registry, proxy, ports, DNS, and certificates before you deploy." ] ]
        ]
      )
      md <<~'MD'
        The shared basics — services, roles, accessories, hooks — work the way
        upstream kamal's do, and the [Configuration](/docs/configuration) pages
        here are generated from the gem itself, so they always match the
        installed version.
      MD
    end
  end

  def where_next
    DocsUI::Section("Where next") do
      md <<~'MD'
        - [Installation](/docs/installation) — get the `dash` executable.
        - [Quick start](/docs/quick-start) — your first deploy in five minutes.
        - [From kamal](/docs/from-kamal) — switch an existing kamal app.
        - [Commands](/docs/commands) — the full CLI surface.
      MD
    end
  end
end
