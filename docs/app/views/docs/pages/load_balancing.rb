# frozen_string_literal: true

# The dash-only load balancer: activation, topology, option layering, sharing.
class Views::Docs::Pages::LoadBalancing < DocsUI::Page
  title "Load balancing"
  eyebrow "Proxy"

  def lead = "One proxy fronts the whole fleet — auto-activated for multi-host roles, shareable between apps."

  def content
    the_idea
    activation
    option_layering
    rolling_out
    sharing
    operating
  end

  private

  def the_idea
    DocsUI::Section("The idea") do
      md <<~'MD'
        Upstream kamal runs one proxy per host and leaves multi-host traffic
        distribution to you — external DNS round-robin, a cloud load balancer,
        or nothing. dash runs a **load balancer**: a dash-proxy instance that
        fronts the fleet and distributes requests across all web hosts, while
        each host keeps its own per-app proxy for gapless deploys.

        The load balancer is the layer that sees the whole fleet, so
        fleet-level concerns live there: TLS termination and certificates,
        [rate limiting and IP lists](/docs/traffic-shaping), the
        [response cache](/docs/caching), session affinity, and read routing.
      MD
    end
  end

  def activation
    DocsUI::Section("Activation") do
      md <<~'MD'
        Three forms of `proxy: loadbalancer:`:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          # A dedicated machine (outside `servers:`) or one of the web hosts —
          # on a web host, the loadbalancer takes over that host's proxy container.
          loadbalancer: lb.example.com

          # Or: always run it on the first host of the primary role, even with
          # a single host.
          loadbalancer: true

          # Or: opt out of the automatic activation for multi-host primary roles.
          loadbalancer: false
      YAML
      md <<~'MD'
        **Auto-activation:** when the primary role has more than one host and
        `loadbalancer:` is unset, dash uses the first web host as the load
        balancer. Set `loadbalancer: false` if you front the fleet with your
        own load balancing — this is the main behavior difference from kamal
        when [migrating](/docs/from-kamal) a multi-host app.
      MD
    end
  end

  def option_layering
    DocsUI::Section("Where each option applies") do
      md <<~'MD'
        With a load balancer in front, every proxy deploy option has exactly
        one home — dash enforces the layering so you cannot configure a rate
        limiter that counts the fleet as one client, or an allow list that
        blocks the load balancer itself:

        - **edge** — applied only by the load balancer, stripped from the
          per-host proxies: `host`/`hosts`, `ssl` (certificates, on-demand,
          mTLS), `ssl_redirect`, `ssl_staging`, `ssl_domains`, `basic_auth`,
          `allow_ips`, `client_ip`, `rate_limit`, `session_affinity`,
          `canonical_host`, `redirects`, `cache`, `read_routing`.
        - **per-app** — applied only by the per-host proxies, next to the app:
          `headers`, `rewrites`, `intercept_errors`, `sleep`, `compress`.
        - **both** — each layer runs its own copy, deliberately: healthchecks,
          response/request timeouts, path timeouts, target pool tuning,
          buffering, `path_prefix`, `forward_headers`, logging.

        Without a load balancer, the single proxy is every layer at once and
        the whole surface applies to it. See the generated
        [Proxy reference](/docs/proxy) for each option.
      MD
    end
  end

  def rolling_out
    DocsUI::Section("Rolling out behind it") do
      md <<~'MD'
        Each web host keeps serving its old container until the new one passes
        dash-proxy's health check, so booting hosts in parallel never reduces
        the fleet's capacity. What a serial `boot: limit: 1` buys is blast
        radius — proving the image on one host before the rest — and it pays
        for it with a full boot per host. A **canary** keeps the proof and
        drops the serialisation:
      MD
      DocsUI::Code(<<~YAML, lexer: :yaml)
        boot:
          canary: 1   # first web host boots alone; the other hosts, all roles, boot together
      YAML
      md <<~'MD'
        A failed canary stops the deploy before any other host is touched.
        `limit` and `wait` still apply to the hosts after the canary. Every
        deploy ends with a timing table under `Finished all in` — one row per
        phase and per host, with how long each host waited to become healthy —
        so the effect of `canary`, `wait`, and `proxy/healthcheck/interval` is
        visible rather than guessed. See the [Booting reference](/docs/boot).
      MD
    end
  end

  def sharing
    DocsUI::Section("Sharing one load balancer between apps") do
      md <<~'MD'
        More than one dash app may point `loadbalancer:` at the same host. Each
        app registers its own service on the shared proxy and keeps its own
        `deploy.yml`; the load balancer multiplexes them by hostname. The rules
        dash enforces for that topology:

        - **Service state survives a reboot.** Services persist in the
          `kamal-loadbalancer-config` volume; `dash proxy reboot` only replaces
          the container, and rebooting from app A does not drop app B's routes.
        - **Service names must be unique across apps.** The first app to deploy
          claims the name on the load balancer host; a second app deploying the
          same name fails at deploy time instead of silently winning.
        - **Apps must agree on `proxy/run`.** All of them boot the same
          container; a conflicting run configuration fails the deploy.
        - **`dash proxy remove` refuses** while other apps are installed on the
          load balancer host (`--force` removes it for everyone).
      MD
    end
  end

  def operating
    DocsUI::Section("Operating it") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash proxy loadbalancer info     # status of the loadbalancer container
        dash proxy loadbalancer logs     # its request logs
        dash proxy loadbalancer deploy   # re-register this app's targets
        dash proxy loadbalancer start    # start it (e.g. after a manual stop)
        dash proxy loadbalancer stop     # stop it
      SHELL
      md <<~'MD'
        A normal `dash deploy` keeps the load balancer's targets current — the
        explicit `deploy` subcommand exists for repair, e.g. after restoring a
        host.
      MD
    end
  end
end
