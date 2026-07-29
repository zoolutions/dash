#!/bin/bash

install_kamal() {
  cd /kamal && gem build kamal.gemspec -o /tmp/kamal.gem && gem install /tmp/kamal.gem
}

install_kamal

# Seed the private registry with the proxy image (pulled directly from ghcr.io,
# which bypasses the hub_cache mirror) so the proxy.run.registry option stays
# exercised by the suite — see app_with_roles, which pulls its proxy from
# registry:4443 rather than the default registry.
#
# The tag must match Kamal::Configuration::Proxy::Run::MINIMUM_VERSION, so read it
# from the source instead of hardcoding it here. Hardcoded, the two drift apart on
# every version bump and the failure lands deep inside an unrelated deploy as
# "manifest unknown" — a long way from the line that caused it.
minimum_version=$(grep -oE 'MINIMUM_VERSION *= *"[^"]+"' /kamal/lib/kamal/configuration/proxy/run.rb | head -1 | cut -d'"' -f2)

if [ -z "$minimum_version" ]; then
  echo "setup.sh: could not read MINIMUM_VERSION from lib/kamal/configuration/proxy/run.rb" >&2
  exit 1
fi

proxy_image="ghcr.io/mhenrixon/kamal-proxy:${minimum_version}"

docker pull "$proxy_image"
docker tag "$proxy_image" "registry:4443/${proxy_image}"
docker push "registry:4443/${proxy_image}"

# .ssh is on a shared volume that persists between runs. Clean it up as the
# churn of temporary vm IPs can eventually create conflicts.
rm -f /root/.ssh/known_hosts
