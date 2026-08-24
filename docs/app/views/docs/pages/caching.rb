# frozen_string_literal: true

# The dash-only response cache: policy per service, storage proxy-wide,
# administered with `dash proxy cache`.
class Views::Docs::Pages::Caching < DocsUI::Page
  title "Response caching"
  eyebrow "Proxy"

  def lead = "An RFC 9111 shared cache in front of your app — policy per service, storage per proxy."

  def content
    the_model
    the_policy
    the_storage
    administering
    when_it_is_not_caching
  end

  private

  def the_model
    DocsUI::Section("The model") do
      md <<~'MD'
        dash-proxy can run an **RFC 9111 shared cache** in front of your app —
        the standard HTTP caching model, driven entirely by the response
        headers your app already sets. Nothing is stored unless the app marks a
        response `public` with an `s-maxage` or `max-age`, and a response
        carrying `Set-Cookie` is refused unless you say otherwise — a shared
        cache replaying one client's cookie to the next is the worst thing it
        could do.

        The configuration splits in two, on the policy/mechanism line:

        - `proxy: cache:` — the **policy**, per service: what this app allows
          to be stored.
        - `proxy: run: cache:` — the **storage**, proxy-wide: where entries
          live for every service on the proxy.

        With a [load balancer](/docs/load-balancing), the cache runs there —
        the one layer that sees the whole fleet.
      MD
    end
  end

  def the_policy
    DocsUI::Section("The policy (per service)") do
      md <<~'MD'
        Only `enabled` is required; everything else keeps dash-proxy's own
        default until you set it:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml")
        proxy:
          cache:
            enabled: true
            max_ttl: 300             # cap the lifetime the app asks for (seconds)
            max_body: 1_048_576      # largest response body to store (bytes)
            max_variants: 8          # representations one URL may hold under Vary
            vary_headers:            # request headers added to EVERY cache key
              - Accept-Encoding
            vary_cookies:            # cookie names added to EVERY cache key
              - locale
            allow_set_cookie: false  # refuse Set-Cookie responses (the safe default)
      YAML
      md <<~'MD'
        `max_ttl` means one mistaken `Cache-Control` cannot pin content until
        the next deploy. Responses bigger than `max_body` still reach the
        client — they are just not kept. Headers the app already names in
        `Vary` are keyed automatically per URL; `vary_headers` moves a header
        into the key for **every** path in the service, which is usually not
        what you want.
      MD
    end
  end

  def the_storage
    DocsUI::Section("The storage (proxy-wide)") do
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml")
        proxy:
          run:
            cache:
              store: redis://cache.example.com:6379/0   # or `memory` (the default)
              store_timeout: 2
              memory_size: 134_217_728
      YAML
      md <<~'MD'
        `memory` is a per-node cache. A `redis://` / `rediss://` URL is shared
        by every proxy pointed at it, so one fetch warms the whole fleet. The
        URL is delivered as `CACHE_STORE` in a `0600` env file on the host —
        never on the command line — so a password in it stays out of process
        listings and the audit log. Changing only the URL's *value* does not
        move the drift digest: run `dash proxy reboot` after rotating it.

        `store_timeout` is the fail-open guard for a shared store: how long the
        store may take to answer before the request goes to the app instead. A
        slow or down store costs a cache hit, never a failed request.
      MD
    end
  end

  def administering
    DocsUI::Section("Administering it") do
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash proxy cache stats               # what the cache is holding
        dash proxy cache stats --count       # entries and bytes per service
        dash proxy cache stats --json        # the raw report
        dash proxy cache purge               # drop this app's cached responses
        dash proxy cache purge --path-prefix /assets
      SHELL
      md <<~'MD'
        Both run on the layer that owns the cache — the load balancer when load
        balancing, else each proxy host.
      MD
    end
  end

  def when_it_is_not_caching
    DocsUI::Section("When it is not caching") do
      md <<~'MD'
        A cache that quietly stores nothing is the usual first surprise. Start
        with `dash proxy cache stats`; dash-proxy also explains every refusal —
        check `dash proxy logs` for the reason, and the `cache_refusals_total`
        Prometheus metric (by `reason`) if you run with `metrics_port`. The
        common reasons:

        - no `Cache-Control: public, max-age=...` on the app's response,
        - a `Set-Cookie` header (with `allow_set_cookie: false`),
        - a body over `max_body`,
        - `variant_limit` from `max_variants`.
      MD
    end
  end
end
