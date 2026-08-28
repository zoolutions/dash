# frozen_string_literal: true

# The dash-only traffic controls: client identity, rate limiting, IP and
# user-agent lists, per-path timeouts, read routing, affinity, scale to zero.
class Views::Docs::Pages::TrafficShaping < DocsUI::Page
  title "Traffic shaping"
  eyebrow "Proxy"

  def lead = "Rate limits, IP lists, per-path deadlines, read routing, session affinity, and scale to zero — at the proxy, not in your app."

  def content
    client_identity
    rate_limiting
    ip_and_agent_lists
    deadlines
    fleet_routing
    scale_to_zero
  end

  private

  def client_identity
    DocsUI::Section("First: who the client is") do
      md <<~'MD'
        Rate limiting and IP lists are only as correct as the address they key
        on, so configure `client_ip` first if anything sits in front of
        dash-proxy. With no `trusted_proxies`, the client is always the address
        that opened the connection — nothing a client sends can influence it.
        Once you declare `trusted_proxies` (and only when the connecting
        address is one of them), the proxy walks the forwarded chain backwards
        past every proxy you declared; the first address none of them wrote is
        the client. **List every hop** — a chain the proxy cannot resolve
        denies the request rather than falling back.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          client_ip:
            header: CF-Connecting-IP    # only honoured with trusted_proxies set
            trusted_proxies:
              - 173.245.48.0/20
              - 2400:cb00::/32
      YAML
    end
  end

  def rate_limiting
    DocsUI::Section("Rate limiting") do
      md <<~'MD'
        A per-client token bucket; requests over the limit get a 429. IPv6
        clients are counted per /64, since one client can pick any address
        inside its own.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          rate_limit:
            requests: 100    # per second, may be fractional (0.5 = one per 2s)
            burst: 20        # back-to-back allowance (default: the rate, rounded up)
            exempt:          # addresses the limit skips — monitors, health probes
              - 10.0.0.0/8
      YAML
    end
  end

  def ip_and_agent_lists
    DocsUI::Section("Allow, deny, and user-agent lists") do
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          allow_ips:            # serve only these; everything else gets a 403
            - 10.0.0.0/8
          deny_ips:             # refuse these — checked before allow_ips
            - 203.0.113.0/24
          deny_user_agents:     # RE2 patterns against the full User-Agent
            - 'BadBot/.*'
      YAML
      md <<~'MD'
        An address on both lists is denied, and denied clients never spend
        rate-limit budget. User-agent patterns are checked after the IP rules;
        a missing User-Agent only matches an explicit `^$` pattern.

        Two enforcement notes, straight from the config validation:

        - The health check path is served without an address check or a rate
          limit, so it stays reachable during a deploy — which is why dash
          rejects `healthcheck: path: /` while either feature is on.
        - With a [load balancer](/docs/load-balancing), all of this moves to
          the load balancer: an allow list on the per-host proxies would refuse
          every request (they only ever see the load balancer), and one rate
          limiter would count the whole fleet as a single client.
      MD
    end
  end

  def deadlines
    DocsUI::Section("Two deadlines, per path") do
      md <<~'MD'
        `response_timeout` bounds how long the app may take to **start**
        answering — its clock stops once response headers arrive.
        `request_timeout` bounds the whole request, including streaming the
        body back. They are not interchangeable: a slow trickle of body bytes
        never trips `response_timeout`, because the app answered promptly.
        WebSocket and event-stream responses are exempt from `request_timeout`.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          response_timeout: 10   # default 30s
          request_timeout: 30    # default 0 = no limit

          # Override either deadline below a path prefix; 0 removes the limit,
          # which suits streaming and SSE endpoints.
          path_response_timeouts:
            "/api/reports": "5m"
            "/stream": 0
          path_request_timeouts:
            "/uploads": "10m"
            "/stream": 0
      YAML
    end
  end

  def fleet_routing
    DocsUI::Section("Read routing & session affinity") do
      md <<~'MD'
        `read_routing` splits traffic between the deployed (writer) targets and
        read-only targets — app instances backed by database replicas. Read
        requests go to the read targets; writes always go to the writers, and
        `writer_affinity_timeout` keeps a client's reads on the writer briefly
        after it writes, so clients always read their own writes.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          read_routing:
            targets:
              - 192.168.0.2:3000
              - 192.168.0.3:3000
            websockets: true             # route WebSockets to readers too (default false)
            writer_affinity_timeout: 10  # seconds; default 1

          session_affinity:
            enabled: true                # pin each client to the target that first served it
            cookie: _kamal_affinity      # rename the (HttpOnly, opaque) pin cookie
      YAML
      md <<~'MD'
        Affinity is off by default, rightly — it exists for apps holding
        session state in the instance. When a pinned target leaves the pool,
        the next request falls through and re-pins, so a deploy strands nobody.
        With a load balancer, both features are decided there — the only layer
        that sees the whole fleet.
      MD
    end
  end

  def scale_to_zero
    DocsUI::Section("Scale to zero") do
      md <<~'MD'
        Stop the service's containers after `after` seconds with no traffic,
        and start them again on the next request, which is held until they are
        healthy. Health checks and the proxy's own TLS probes are not traffic
        and never wake a sleeping service.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        proxy:
          sleep:
            after: 300         # idle seconds before stopping
            wake_timeout: 30   # how long a request waits before a 503
          run:
            docker_socket: /var/run/docker.sock
      YAML
      DocsUI::Callout(:warning) do
        plain "Stopping and starting containers means talking to the runtime, so "
        code { "run/docker_socket" }
        plain " must be set — and reaching that socket is root-equivalent on the host, which is why it is a separate, explicit setting. Not compatible with on-demand TLS: a sleeping target cannot answer the ask endpoint."
      end
    end
  end
end
