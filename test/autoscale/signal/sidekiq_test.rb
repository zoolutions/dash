require "test_helper"
require_relative "fakes"

class AutoscaleSignalSidekiqTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)

  test "the age of the oldest job across the queues: the right end of each list" do
    redis = redis_with("default" => job(NOW.to_f - 3.5), "billing" => job(NOW.to_f - 42.25))
    sample = reader(redis).sample(at: NOW)

    assert_in_delta 42.25, sample.value, 0.001
    assert_equal NOW, sample.at
    assert_nil sample.error
    assert_equal [ [ "LINDEX", "queue:default", -1 ], [ "LINDEX", "queue:billing", -1 ] ], redis.commands
  end

  test "Sidekiq 8 writes enqueued_at in integer milliseconds" do
    redis = redis_with("default" => job(((NOW.to_f - 12) * 1000).to_i), "billing" => nil)

    assert_in_delta 12, reader(redis).sample(at: NOW).value, 0.001
  end

  test "empty queues are no latency" do
    assert_equal 0, reader(redis_with("default" => nil, "billing" => nil)).sample(at: NOW).value
  end

  test "a job enqueued after the sample (clock skew) is no latency, not negative" do
    assert_equal 0, reader(redis_with("default" => job(NOW.to_f + 5), "billing" => nil)).sample(at: NOW).value
  end

  test "a malformed job, a job without enqueued_at or a Redis error is a missing sample, never an exception" do
    [ redis_with("default" => "{not json", "billing" => nil),
      redis_with("default" => JSON.generate("class" => "BillingJob"), "billing" => nil),
      AutoscaleSignalFakes::Redis.new([ "LINDEX", "queue:default", -1 ] => RuntimeError.new("READONLY You can't write against a read only replica")) ].each do |redis|
      sample = reader(redis).sample(at: NOW)

      assert sample.missing?
      assert_nil sample.value
      assert_predicate sample.error, :present?
    end
  end

  test "a connection that cannot be made is a missing sample naming the error" do
    connections = AutoscaleSignalFakes::Connections.new(redis: RuntimeError.new("Connection refused - connect(2) for 10.0.0.5:6379"))
    sample = Dash::Autoscale::Signal::Sidekiq.new(signal, connections).sample(at: NOW)

    assert_equal "RuntimeError: Connection refused - connect(2) for 10.0.0.5:6379", sample.error
  end

  test "a configuration error is not a missing sample: it reaches the operator" do
    connections = AutoscaleSignalFakes::Connections.new(redis: Dash::ConfigurationError.new("autoscale/redis/url: is blank"))

    assert_raises(Dash::ConfigurationError) { Dash::Autoscale::Signal::Sidekiq.new(signal, connections).sample(at: NOW) }
  end

  test "busy sums the jobs in progress of the processes running in the given containers" do
    redis = AutoscaleSignalFakes::Redis.new(
      [ "SMEMBERS", "processes" ] => [ "app-1:1:aa", "app-2:1:bb", "gone:1:cc" ],
      [ "HMGET", "app-1:1:aa", "info", "busy" ] => [ JSON.generate("hostname" => "10.0.0.31-aaaaaaaaaaaa"), "3" ],
      [ "HMGET", "app-2:1:bb", "info", "busy" ] => [ JSON.generate("hostname" => "10.0.0.31-bbbbbbbbbbbb"), "5" ],
      [ "HMGET", "gone:1:cc", "info", "busy" ] => [ nil, nil ])
    sidekiq = reader(redis)

    assert sidekiq.busy?
    assert_equal 3, sidekiq.busy([ "10.0.0.31-aaaaaaaaaaaa" ])
    assert_equal 8, sidekiq.busy([ "10.0.0.31-aaaaaaaaaaaa", "10.0.0.31-bbbbbbbbbbbb" ])
    assert_equal 0, sidekiq.busy([ "10.0.0.32-cccccccccccc" ])
  end

  test "only reads" do
    redis = redis_with("default" => job(NOW.to_f - 1), "billing" => nil)
    redis.instance_variable_get(:@replies)[[ "SMEMBERS", "processes" ]] = []
    sidekiq = reader(redis)
    sidekiq.sample(at: NOW)
    sidekiq.busy([ "x" ])

    assert_empty redis.commands.map(&:first).uniq - %w[ LINDEX SMEMBERS HMGET ]
  end

  private
    def signal
      Dash::Configuration::Role::Scale::Signal.new(signal_config: { "source" => "sidekiq", "queues" => [ "default", "billing" ] }, context: "test")
    end

    def reader(redis)
      Dash::Autoscale::Signal::Sidekiq.new(signal, AutoscaleSignalFakes::Connections.new(redis: redis))
    end

    def redis_with(oldest)
      AutoscaleSignalFakes::Redis.new(oldest.to_h { |queue, job| [ [ "LINDEX", "queue:#{queue}", -1 ], job ] })
    end

    def job(enqueued_at)
      JSON.generate("class" => "BillingJob", "queue" => "billing", "enqueued_at" => enqueued_at)
    end
end
