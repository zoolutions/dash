# Web request queue time in milliseconds: the 95th percentile of the last minute across
# every container of the role on every host, from the windows each host's dash-proxy keeps
# per target (Dash::Diagnostics::ProxyQueue). The buckets are merged before the percentile
# is read, so a host weighs by its traffic.
#
# No requests in the window is a queue time of 0, so an idle role can scale in. A host
# that cannot be read is named in the detail and the rest still answer (the tick's
# Observation holds the role anyway when a baseline host is unreadable); no host answering
# is a missing sample.
class Dash::Autoscale::Signal::Proxy < Dash::Autoscale::Signal
  QUANTILE = 0.95

  # `queue` reads the role's windows; tests hand it a fake.
  def initialize(config, connections, role: nil, queue: ->(role) { Dash::Diagnostics::ProxyQueue.new(role: role).to_h })
    super(config, connections, role: role)
    @queue = queue
  end

  def sample(at: Time.now.utc)
    @detail = nil
    super.tap { |sample| sample.detail = @detail }
  end

  private
    def read(_at)
      hosts = @queue.call(role)[:hosts]
      answered = hosts.reject { |host| host[:error] }
      targets = answered.flat_map { |host| host[:targets] }
      fleet = histogram(targets)

      @detail = { unit: "ms", window_seconds: targets.filter_map { |target| target[:window_seconds] }.first, requests: fleet.count,
        measured_by: { app: targets.sum { |target| target[:app].to_i }, proxy: targets.sum { |target| target[:proxy].to_i } },
        hosts: hosts.map { |host| host[:error] ? host.slice(:host, :error) : host_detail(host) } }

      raise "no dash-proxy of #{role.name} answered: #{hosts.map { |host| "#{host[:host]} (#{host[:error]})" }.join(", ")}" if answered.empty?

      fleet.quantile(QUANTILE).round(1)
    end

    def host_detail(host)
      histogram = histogram(host[:targets])

      { host: host[:host], targets: host[:targets].size, requests: histogram.count, p95_ms: histogram.quantile(QUANTILE).round(1) }
    end

    def histogram(targets)
      Dash::Autoscale::Histogram.merge(targets.map { |target| Dash::Autoscale::Histogram.new(buckets: target[:buckets], count: target[:requests]) })
    end
end
