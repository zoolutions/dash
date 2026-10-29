require "test_helper"
require_relative "fakes"

class AutoscaleSignalPgbusTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 2, 0, 0)

  test "the age of the oldest claimable message across the queues, in one read-only transaction" do
    postgres = AutoscaleSignalFakes::Postgres.new(sql("pgbus_default") => "3.5", sql("pgbus_billing") => "41.75")
    sample = reader(postgres).sample(at: NOW)

    assert_equal 41.75, sample.value
    assert_equal [ "BEGIN READ ONLY", "SET LOCAL statement_timeout = 5000", sql("pgbus_default"), sql("pgbus_billing"), "ROLLBACK" ], postgres.statements
  end

  test "an empty queue (min over no rows) is no latency" do
    assert_equal 0, reader(AutoscaleSignalFakes::Postgres.new(sql("pgbus_default") => nil, sql("pgbus_billing") => nil)).sample(at: NOW).value
  end

  test "the table prefix comes from the signal" do
    postgres = AutoscaleSignalFakes::Postgres.new(sql("jobs_default") => "1", sql("jobs_billing") => "2")

    assert_equal 2, reader(postgres, prefix: "jobs_").sample(at: NOW).value
  end

  test "a missing table is a missing sample, and the transaction is still rolled back" do
    postgres = AutoscaleSignalFakes::Postgres.new(sql("pgbus_default") => RuntimeError.new(%(PG::UndefinedTable: relation "pgmq.q_pgbus_default" does not exist)))
    sample = reader(postgres).sample(at: NOW)

    assert sample.missing?
    assert_match "PG::UndefinedTable", sample.error
    assert_equal "ROLLBACK", postgres.statements.last
  end

  test "pgbus has no busy count" do
    assert_not reader(AutoscaleSignalFakes::Postgres.new).busy?
  end

  private
    def reader(postgres, prefix: nil)
      config = { "source" => "pgbus", "queues" => [ "default", "billing" ], "prefix" => prefix }.compact
      signal = Dash::Configuration::Role::Scale::Signal.new(signal_config: config, context: "test")
      Dash::Autoscale::Signal::Pgbus.new(signal, AutoscaleSignalFakes::Connections.new(postgres: postgres))
    end

    def sql(table)
      %(SELECT EXTRACT(epoch FROM now() - min(vt)) FROM pgmq."q_#{table}" WHERE vt <= now())
    end
end
