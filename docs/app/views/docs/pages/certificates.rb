# frozen_string_literal: true

# The dash-only TLS surface: SAN batching, wildcard certs via DNS-01,
# dynamic domains, on-demand TLS, and certificate import/export.
class Views::Docs::Pages::Certificates < DocsUI::Page
  title "SAN batching & wildcards"
  eyebrow "Proxy"

  def lead = "Batch domains onto shared SAN certificates, issue wildcards via DNS-01, and learn hostnames from your app at runtime."

  def content
    beyond_one_host_one_cert
    dynamic_domains
    wildcards
    on_demand
    moving_certificates
  end

  private

  def beyond_one_host_one_cert
    DocsUI::Section("Beyond one host, one cert") do
      md <<~'MD'
        Upstream kamal's automatic TLS is one Let's Encrypt certificate per
        configured `host`, HTTP-01 only, single-server. dash-proxy extends the
        whole surface:

        - **SAN batching** — many domains share one certificate, so a
          multi-tenant app with hundreds of custom domains doesn't run into
          Let's Encrypt rate limits one cert at a time.
        - **Wildcard certificates** — issued via DNS-01 challenges against your
          DNS provider's API.
        - **Dynamic TLS domains** — the proxy polls your application for the
          hostname list instead of fixing it at deploy time.
        - **On-demand TLS** — the proxy asks your app per-handshake whether to
          issue for an unknown hostname.
        - **mTLS** — `ssl: client_ca_pem:` requires client certificates signed
          by your CA bundle.

        All of it terminates at the [load balancer](/docs/load-balancing) when
        one fronts the fleet — certificates are edge concerns.
      MD
    end
  end

  def dynamic_domains
    DocsUI::Section("Dynamic TLS domains & SAN batching") do
      md <<~'MD'
        `ssl_domains` tells the proxy to learn hostnames from your application
        at runtime: it polls `source` — a path resolved against a healthy app
        target, or an absolute URL — for the domain list and manages Let's
        Encrypt certificates for it automatically. With `source` set,
        `ssl: true` is allowed without `host`/`hosts`.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          ssl: true
          ssl_domains:
            source: /api/v1/kamal/domains
            interval: 300     # poll interval in seconds (proxy default: 300)
            batch_size: 25    # 1 = per-domain certs; 2-25 = stable SAN batching
      YAML
      md <<~'MD'
        `batch_size` is the SAN-batching knob: how many domains share one
        certificate. The batching is **stable** — a domain joining or leaving
        doesn't reshuffle every other domain's certificate.

        Authentication tokens for the poll endpoint and the refresh nudge are
        read from `KAMAL_PROXY_DOMAINS_TOKEN` and `KAMAL_PROXY_REFRESH_TOKEN`
        on the proxy container — set them via `proxy.run.options.env`, never as
        deploy flags. Operate the domain list with:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash proxy domains list      # what the proxy currently serves
        dash proxy domains stats     # certificate issuance state
        dash proxy domains refresh   # nudge an immediate re-poll
      SHELL
    end
  end

  def wildcards
    DocsUI::Section("Wildcard certificates (DNS-01)") do
      md <<~'MD'
        DNS-01 issuance is configured proxy-wide under `proxy: run: acme:` —
        every service on the proxy shares the ACME account and DNS provider.
        DNS-01 activates **only** when `dns_provider` is set; unset means
        HTTP-01 only, so credentials visible in the proxy's environment can
        never arm DNS-01 on their own.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          run:
            acme:
              email: admin@example.com
              # One provider for every zone, or a hash pinning zones to the DNS
              # host that serves them, with `default` for the rest.
              dns_provider:
                platform.example: cloudflare
                legacy.example: hetzner
                default: route53
              prefer_wildcard: true   # ask for a wildcard when the provider supports it
              http_fallback: true     # fall back to HTTP-01 when DNS-01 fails
              credentials:
                - CF_DNS_API_TOKEN    # secret names, passed to the proxy as env vars
      YAML
      md <<~'MD'
        Providers: cloudflare, digitalocean, gcloud, godaddy, hetzner,
        namecheap, route53, vultr (plus `auto`, which picks from the
        credentials it can see and logs which one it armed). `credentials`
        names entries in `.dash/secrets`; they are written to a `0600` env
        file on the proxy host and passed with `--env-file`, never on the
        command line.

        While working out a DNS setup, point `directory` at Let's Encrypt's
        staging environment so failed attempts don't burn production rate
        limits.
      MD
      DocsUI::Callout(:warning) do
        plain "A DNS API token can rewrite your zone. Rotating a credential value does not change the proxy's config digest — run "
        code { "dash proxy reboot" }
        plain " yourself after a rotation."
      end
    end
  end

  def on_demand
    DocsUI::Section("On-demand TLS & custom certificates") do
      md <<~'MD'
        The `ssl:` hash is home to the rest of the TLS surface:

        - `certificate_pem` / `private_key_pem` — bring your own certificate,
          loaded from `.dash/secrets`.
        - `on_demand_url` — instead of a fixed host list, the proxy asks this
          endpoint whether it may issue for the hostname in an incoming
          handshake (2xx approves). Mutually exclusive with `host`/`hosts`,
          `certificate_pem`, and `ssl_domains` — dash rejects the combination
          at config time.
        - `client_ca_pem` — mutual TLS: clients must present a certificate
          signed by this CA bundle.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          ssl:
            certificate_pem: CERTIFICATE_PEM
            private_key_pem: PRIVATE_KEY_PEM
      YAML
    end
  end

  def moving_certificates
    DocsUI::Section("Moving certificates between hosts") do
      md <<~'MD'
        Issued certificates are state worth keeping — reissuing hundreds of
        domains on a host move would take hours and eat rate limits. dash can
        export and import the proxy's certificate store:
      MD
      DocsUI::Code(<<~SHELL, lexer: :shell)
        dash proxy export_certs ./certs.tar.gz   # contains private keys — handle accordingly
        dash proxy import_certs                  # from an exported archive, or a Traefik acme.json
      SHELL
      md <<~'MD'
        `import_certs` also understands Traefik's `acme.json`, which is the
        escape hatch for migrating a Traefik-fronted fleet onto dash-proxy
        without reissuing.
      MD
    end
  end
end
