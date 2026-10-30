# `dash-proxy list --json` as v1.1.0.5 answers it: per service, `target_details` with each
# target's 60 s queue window (cumulative counts per finite bound in ms; the +Inf count is
# `requests` minus the last one).
module ProxyQueueFixtures
  BOUNDS = [ 10.0, 25.0, 50.0, 100.0 ]

  private
    def list(services)
      { services: services.transform_values { |targets| { targets: targets.map { |target| target[:address] }, target_details: targets } } }.to_json
    end

    def target(address, requests:, cumulative:, app: 0, proxy: 0, slot: "active", p95_ms: 9.5, max_ms: 20.0)
      { address: address, slot: slot, state: "healthy", in_flight: 1,
        queue: { window_seconds: 60, requests: requests, sum_ms: 1.0, max_ms: max_ms, p95_ms: p95_ms, app: app, proxy: proxy,
          buckets: BOUNDS.zip(cumulative).map { |bound, count| { le_ms: bound, count: count } } } }
    end
end
