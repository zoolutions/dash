require_relative "diagnostics_test_case"
require_relative "../autoscale/signal/fakes"

# payments: a Sidekiq signal on the payments queue, held between 2 and 10 seconds, and a
# Postgres guard above 180. reports: a schedule and no signal.
class DiagnosticsAutoscaleSignalTest < DiagnosticsTestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)
  GUARD = "SELECT count(*) FROM pg_stat_activity"

  setup do
    configure :deploy_with_scale_signal
    @redis = AutoscaleSignalFakes::Redis.new([ "LINDEX", "queue:payments", -1 ] => JSON.generate("enqueued_at" => NOW.to_f - 12.5))
    @postgres = AutoscaleSignalFakes::Postgres.new(GUARD => "195")
    @connections = AutoscaleSignalFakes::Connections.new(redis: @redis, postgres: @postgres)
    Socket.stubs(:gethostname).returns("laptop")
  end

  test "one live sample of the signal and of each guard, timed, with the band and where it was read from" do
    signal = sample(:payments)

    assert_equal [ "payments", true, "laptop" ], signal.values_at(:role, :configured, :from)
    assert_equal({ source: "sidekiq", value: 12.5, at: NOW.iso8601, error: nil }, signal[:signal].except(:latency_ms))
    assert_kind_of Numeric, signal[:signal][:latency_ms]
    assert_equal({ index: 0, source: "postgres", above: 180, value: 195.0, at: NOW.iso8601, error: nil, holding: true }, signal[:guards].first.except(:latency_ms))
    assert_kind_of Numeric, signal[:guards].first[:latency_ms]
    assert_equal({ up_above: 10, up_for: 30, down_below: 2, down_for: 600 }, signal[:band])
  end

  test "where the sample sits against the band" do
    assert_equal "above", sample(:payments)[:position]

    @redis = AutoscaleSignalFakes::Redis.new([ "LINDEX", "queue:payments", -1 ] => JSON.generate("enqueued_at" => NOW.to_f - 1))
    @connections = AutoscaleSignalFakes::Connections.new(redis: @redis, postgres: @postgres)
    assert_equal "below", sample(:payments)[:position]
  end

  test "a source that cannot be read is the sample's error, the guards are still read" do
    @connections = AutoscaleSignalFakes::Connections.new(redis: Errno::ECONNREFUSED.new("cache.internal:6379"), postgres: @postgres)
    signal = sample(:payments)

    assert_nil signal[:signal][:value]
    assert_equal "Errno::ECONNREFUSED: Connection refused - cache.internal:6379", signal[:signal][:error]
    assert_nil signal[:position]
    assert_equal 195.0, signal[:guards].first[:value]
  end

  test "a configuration error (a missing gem, an empty secret) is an error to show, not a crash" do
    @connections = AutoscaleSignalFakes::Connections.new(redis: Dash::ConfigurationError.new("autoscale/redis: needs the redis-client gem"),
      postgres: Dash::ConfigurationError.new("autoscale/postgres: needs the pg gem"))
    signal = sample(:payments)

    assert_equal "Dash::ConfigurationError: autoscale/redis: needs the redis-client gem", signal[:signal][:error]
    assert_equal "Dash::ConfigurationError: autoscale/postgres: needs the pg gem", signal[:guards].first[:error]
    assert signal[:guards].first[:holding], "a guard that cannot be read holds, as in the controller"
  end

  test "a role without a signal answers that it has none" do
    assert_equal({ role: "reports", configured: false, message: "reports has no scale/signal, so there is nothing to sample" }, sample(:reports).except(:generated_at))
  end

  test "it closes the connections it opened, and leaves the ones it was given" do
    Dash::Autoscale::Connections.stubs(:new).returns(@connections)
    Dash::Diagnostics::AutoscaleSignal.new(role: DASH.config.role(:payments), now: NOW).to_h
    assert @connections.closed

    given = AutoscaleSignalFakes::Connections.new(redis: @redis, postgres: @postgres)
    Dash::Diagnostics::AutoscaleSignal.new(role: DASH.config.role(:payments), now: NOW, connections: given).to_h
    assert_not given.closed
  end

  test "only reads: LINDEX, SMEMBERS and HMGET on Redis, and Postgres inside a read-only transaction it rolls back" do
    sample(:payments)

    assert_empty @redis.commands.map(&:first).uniq - %w[ LINDEX SMEMBERS HMGET ]
    assert_equal [ "BEGIN READ ONLY", "SET LOCAL statement_timeout = 5000", GUARD, "ROLLBACK" ], @postgres.statements
  end

  private
    def sample(role)
      Dash::Diagnostics::AutoscaleSignal.new(role: DASH.config.role(role), now: NOW, connections: @connections).to_h
    end
end
