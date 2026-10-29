require "test_helper"

class ConfigurationRoleScaleSignalTest < ActiveSupport::TestCase
  test "sidekiq reads queues" do
    signal = signal("source" => "sidekiq", "queues" => [ "default", "billing" ])

    assert_equal "sidekiq", signal.source
    assert_equal [ "default", "billing" ], signal.queues
    assert_nil signal.prefix
    assert_nil signal.query
    assert signal.queues?
    assert_equal "redis", signal.connection
  end

  test "pgbus reads queues with the pgmq table prefix, pgbus_ by default" do
    assert_equal "pgbus_", signal("source" => "pgbus", "queues" => [ "default" ]).prefix
    assert_equal "jobs_", signal("source" => "pgbus", "queues" => [ "default" ], "prefix" => "jobs_").prefix
    assert_equal "postgres", signal("source" => "pgbus", "queues" => [ "default" ]).connection
  end

  test "prometheus reads one query" do
    signal = signal("source" => "prometheus", "query" => "max(job_queue_latency_seconds)")

    assert_not signal.queues?
    assert_equal "max(job_queue_latency_seconds)", signal.query
    assert_equal "prometheus", signal.connection
    assert_equal({ source: "prometheus", query: "max(job_queue_latency_seconds)" }, signal.to_h)
  end

  private
    def signal(config)
      Dash::Configuration::Role::Scale::Signal.new(signal_config: config, context: "servers/workers/scale/signal")
    end
end
