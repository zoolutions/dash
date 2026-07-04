#!/bin/bash

install_kamal() {
  cd /kamal && gem build kamal.gemspec -o /tmp/kamal.gem && gem install /tmp/kamal.gem
}

install_kamal

# Seed the private registry with the proxy image (pulled directly from ghcr.io,
# which bypasses the hub_cache mirror) so the proxy.run.registry option stays
# exercised by the suite — see app_with_roles, which pulls its proxy from
# registry:4443 rather than the default registry. The tag must match
# Kamal::Configuration::Proxy::Run::MINIMUM_VERSION.
docker pull ghcr.io/mhenrixon/kamal-proxy:v0.9.2.1
docker tag ghcr.io/mhenrixon/kamal-proxy:v0.9.2.1 registry:4443/ghcr.io/mhenrixon/kamal-proxy:v0.9.2.1
docker push registry:4443/ghcr.io/mhenrixon/kamal-proxy:v0.9.2.1

# .ssh is on a shared volume that persists between runs. Clean it up as the
# churn of temporary vm IPs can eventually create conflicts.
rm -f /root/.ssh/known_hosts
