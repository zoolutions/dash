require "test_helper"
require_relative "fakes"

class AutoscaleSignalPrometheusTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)
  QUERY = %(max(job_queue_latency_seconds{queue="billing"}))

  test "the query's value, from exactly the query configured" do
    assert_equal 7.5, reader(QUERY => 7.5).sample(at: NOW).value
    assert_equal [ QUERY ], @prometheus.queries
  end

  test "no series, NaN or Inf is a missing sample" do
    [ nil, Float::NAN, Float::INFINITY ].each do |value|
      sample = reader(QUERY => value).sample(at: NOW)

      assert sample.missing?, value.inspect
      assert_nil sample.to_h[:value]
    end
  end

  test "an HTTP error is a missing sample" do
    sample = reader(QUERY => RuntimeError.new("Prometheus answered HTTP 503")).sample(at: NOW)

    assert_equal "RuntimeError: Prometheus answered HTTP 503", sample.error
  end

  private
    def reader(values)
      signal = Dash::Configuration::Role::Scale::Signal.new(signal_config: { "source" => "prometheus", "query" => QUERY }, context: "test")
      @prometheus = AutoscaleSignalFakes::Prometheus.new(values)
      Dash::Autoscale::Signal::Prometheus.new(signal, AutoscaleSignalFakes::Connections.new(prometheus: @prometheus))
    end
end
