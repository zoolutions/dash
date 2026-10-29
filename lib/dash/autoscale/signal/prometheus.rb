# The value of one PromQL query, the largest when it returns several series. No series, NaN
# or Inf is a missing sample (Dash::Autoscale::Sample#missing?).
class Dash::Autoscale::Signal::Prometheus < Dash::Autoscale::Signal
  private
    def read(_at)
      connections.with(:prometheus) { |prometheus| prometheus.query(config.query) }
    end
end
