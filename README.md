# dash: Deploy web apps anywhere

From bare metal to cloud VMs, deploy web apps anywhere with zero downtime. dash uses [dash-proxy](https://github.com/zoolutions/dash-proxy) to seamlessly switch requests between containers, load-balance across multiple hosts, batch SAN certificates, and issue wildcard certs via DNS-01. Works across multiple servers, using SSHKit to execute commands. Originally built for Rails apps, dash works with any type of web app that can be containerized with Docker.

dash began as a fork of [basecamp/kamal](https://github.com/basecamp/kamal) and made a clean break in 2026 — it ships the features upstream wouldn't merge (proxy load balancing, readiness gates, response caching, traffic shaping, and more) and moves at its own pace. Existing kamal deployments upgrade in place: the on-server artifacts (`.kamal/` directory, `kamal-proxy` container) are unchanged, `KAMAL_*` env vars are still set alongside their `DASH_*` twins, and a `.kamal/` directory in your own repo is still read — `dash migrate` moves it to `.dash/` when you're ready.

## Installation

```bash
gem install dash
dash init
```

Or in a Gemfile-managed app:

```bash
bundle add dash
bundle binstubs dash
bin/dash init
```

Configure your deployment in `config/deploy.yml`, then:

```bash
dash setup     # first deploy: bootstraps Docker, boots the proxy, deploys
dash deploy    # every deploy after that
```

`dash docs` prints the full, always-current configuration reference. Upstream kamal's docs at [kamal-deploy.org](https://kamal-deploy.org) still cover the shared basics.

## License

dash is released under the [MIT License](https://opensource.org/licenses/MIT), preserving the license of the kamal codebase it descends from.
