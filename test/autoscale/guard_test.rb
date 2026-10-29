require "test_helper"
require_relative "signal/fakes"

class AutoscaleGuardTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)
  ACTIVITY = "SELECT count(*) FROM pg_stat_activity"
  WAITING = "max(pgbouncer_pools_client_waiting_connections)"

  test "reads each guard of the role, in order, as a reading with its bound" do
    postgres = AutoscaleSignalFakes::Postgres.new(ACTIVITY => "195")
    readings = Dash::Autoscale::Guard.read(guards, connections(postgres: postgres, prometheus: AutoscaleSignalFakes::Prometheus.new(WAITING => 0.0)), at: NOW)

    assert_equal [ [ 0, "prometheus", 0, 0.0 ], [ 1, "postgres", 180, 195.0 ] ], readings.map { |reading| [ reading.index, reading.source, reading.above, reading.sample.value ] }
    assert_equal [ false, true ], readings.map(&:holding?)
    assert_equal [ "BEGIN READ ONLY", "SET LOCAL statement_timeout = 5000", ACTIVITY, "ROLLBACK" ], postgres.statements
  end

  test "a guard that cannot be read is a reading with an error, and holds" do
    readings = Dash::Autoscale::Guard.read(guards, connections(postgres: RuntimeError.new("could not connect"), prometheus: AutoscaleSignalFakes::Prometheus.new(WAITING => nil)), at: NOW)

    assert_equal [ true, true ], readings.map(&:holding?)
    assert_equal "RuntimeError: could not connect", readings.last.sample.error
  end

  test "a value that is not a number is an error" do
    readings = Dash::Autoscale::Guard.read(guards.last(1), connections(postgres: AutoscaleSignalFakes::Postgres.new(ACTIVITY => "many")), at: NOW)

    assert_match "ArgumentError", readings.first.sample.error
  end

  private
    def guards
      [ { "source" => "prometheus", "query" => WAITING, "above" => 0 }, { "source" => "postgres", "query" => ACTIVITY, "above" => 180 } ]
        .each_with_index.map { |guard, index| Dash::Configuration::Role::Scale::Guard.new(guard_config: guard, context: "hold_when/#{index}") }
    end

    def connections(**clients)
      AutoscaleSignalFakes::Connections.new(**clients)
    end
end
