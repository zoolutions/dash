# What each host's dash-proxy measured of a role's request queue time: per target, the
# trailing window `dash-proxy list --json` reports (v1.1.0.5 on) under `target_details`.
# Read over SSH like Dash::Diagnostics::ProxyServices; the proxy signal
# (Dash::Autoscale::Signal::Proxy) merges it into the fleet's p95.
#
# A host whose proxy cannot be read, does not route the role, or predates the window is
# that host's error; the other hosts still answer.
class Dash::Diagnostics::ProxyQueue < Dash::Diagnostics::Base
  # The role's targets in one `dash-proxy list --json` output, active and rollout slots
  # alike (both serve requests). Buckets are [ [ upper bound ms, cumulative count ], ... ].
  #
  # dash-proxy omits empty lists, so a service with no targets has neither `targets` nor
  # `target_details`; only targets without details is a proxy older than the window.
  def self.targets(output, service:, host:)
    routed = Dash::Commands::Proxy::Services.parse(output)[service] or raise "dash-proxy on #{host} routes no #{service}"
    details = routed.fetch("target_details") do
      raise "dash-proxy on #{host} reports no queue window (it predates v1.1.0.5), run dash proxy reboot" if Array(routed["targets"]).any?

      []
    end

    details.map do |target|
      queue = target.fetch("queue")

      { address: target["address"], slot: target["slot"], state: target["state"], in_flight: target["in_flight"],
        window_seconds: queue["window_seconds"], requests: queue.fetch("requests"), p95_ms: queue["p95_ms"], max_ms: queue["max_ms"], app: queue["app"], proxy: queue["proxy"],
        buckets: queue.fetch("buckets").map { |bucket| [ bucket.fetch("le_ms"), bucket.fetch("count") ] } }
    end
  end

  def initialize(role:)
    @role = role
  end

  private
    def snapshot
      { role: @role.name,
        hosts: per_host(@role.hosts) { |backend, host| { targets: self.class.targets(backend.capture_with_info(*DASH.proxy(host).list(json: true)), service: @role.container_prefix, host: host) } } }
    end
end
