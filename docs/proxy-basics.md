# Proxy basics

The ten `proxy:` keys most apps ever need. The full reference — six tiers,
from these essentials down to the proxy container's own runtime — lives in
[`lib/dash/configuration/docs/proxy.yml`](../lib/dash/configuration/docs/proxy.yml),
which is also the validation schema: any key that file doesn't show is a key
kamal rejects.

```yaml
proxy:
  # Which hostnames route to this app. One of host / hosts.
  host: app.example.com
  hosts:
    - app.example.com
    - www.example.com

  # Automatic HTTPS via Let's Encrypt (needs a host and an open :443),
  # or a hash for custom certificates / on-demand TLS / mTLS.
  ssl: true

  # Redirect HTTP to HTTPS (default true when ssl is on).
  ssl_redirect: true

  # Use Let's Encrypt's staging environment while testing.
  ssl_staging: true

  # The port your app container listens on (default 80).
  app_port: 3000

  # What the proxy polls until the new container is ready.
  healthcheck:
    path: /up
    interval: 1
    timeout: 5

  # Multi-host apps: which host fronts the fleet. Auto-activates on the
  # primary role's first host when it has more than one host; set false to
  # opt out, or name a dedicated machine.
  loadbalancer: lb.example.com

  # Reboot the proxy automatically when its configuration drifts
  # (default true; zero-downtime with run.port_holder).
  reboot_on_deploy: true
```

## Where options apply with a loadbalancer

Every proxy option lives at exactly one layer — the loadbalancer (TLS,
access control, caching, affinity), the per-host proxies (headers, rewrites,
compression, sleep), or deliberately both (health checks, timeouts,
buffering). You don't place them; kamal does. The per-key table is at the top
of the full reference.

## When you need more

| You want | Look at |
|---|---|
| Header rules, redirects, rewrites, canonical host | §2 Traffic & routing |
| Basic auth, IP allow lists, rate limiting, dynamic TLS domains | §3 Security & access |
| Timeouts, connection pools, buffering, compression, response caching | §4 Performance & observability |
| Read/write splitting, session affinity, scale-to-zero | §5 Fleet |
| Ports, ACME/Let's Encrypt DNS credentials, cache store, zero-downtime reboots, escape hatches | §6 Proxy container (`run`) |
