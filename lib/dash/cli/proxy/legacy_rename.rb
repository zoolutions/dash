# Stage 3c migration: brings a host that still carries pre-rename container
# identity onto the renamed one.
#
# Three steps, run in this order on each proxy host before the normal boot:
#
#   1. Bridge the network. Docker cannot rename one, so `dash` is created
#      alongside `kamal` and everything still attached to the old network joins
#      the new one. App containers would be replaced by the next deploy anyway;
#      accessories are not, which is the whole reason this exists — without it a
#      renamed proxy cannot reach `db` or `redis`.
#
#   2. Copy the config volume. It holds the routing table and the ACME account
#      and certificate cache, so losing it means re-issuing every certificate
#      and spending Let's Encrypt rate limits to get back to where we were. This
#      must happen before the new container starts.
#
#   3. Replace the legacy container. A rename means the old container has to
#      release ports 80/443 before the new one can claim them, and no
#      port-holder handoff spans two container names — so this stage accepts a
#      brief outage per host. Deliberate; see zoolutions/dash#124.
#
# Every step is idempotent and guarded on its destination not already existing,
# so a second deploy is a no-op. Nothing here removes the legacy network or
# volume: an operator who wants them gone removes them by hand, and stage 3d
# deletes this class outright.
class Dash::Cli::Proxy::LegacyRename
  attr_reader :host, :sshkit
  delegate :execute, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    bridge_network
    adopt_config_volume
    replace_legacy_container
  end

  private
    def bridge_network
      execute *DASH.docker.connect_legacy_network_containers
    end

    def adopt_config_volume
      execute *DASH.proxy(host).copy_legacy_config_volume
    end

    # The drain timeout the proxy is configured with, so a busy host is not cut
    # off mid-request any more abruptly than a normal reboot would.
    def replace_legacy_container
      proxy = DASH.proxy(host)

      execute *proxy.remove_legacy_container(timeout: DASH.config.drain_timeout)
      execute *proxy.remove_legacy_holder_container
    end
end
