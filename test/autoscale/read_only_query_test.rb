require "test_helper"
require_relative "signal/fakes"

class AutoscaleReadOnlyQueryTest < ActiveSupport::TestCase
  # A Postgres connection whose query never answers.
  class StalledPostgres < AutoscaleSignalFakes::Postgres
    def exec(sql)
      return super unless sql == "SELECT 1"

      @statements << sql
      sleep 5
    end
  end

  test "reads inside a read-only transaction with a statement timeout, always rolled back" do
    postgres = AutoscaleSignalFakes::Postgres.new("SELECT 1" => "1")

    assert_equal 1.0, Dash::Autoscale::ReadOnlyQuery.within(postgres) { Dash::Autoscale::ReadOnlyQuery.number(postgres, "SELECT 1") }
    assert_equal [ "BEGIN READ ONLY", "SET LOCAL statement_timeout = 5000", "SELECT 1", "ROLLBACK" ], postgres.statements
  end

  test "a connection that stops answering times out on the client, without a ROLLBACK on the stalled socket" do
    postgres = StalledPostgres.new

    assert_raises(Timeout::Error) do
      Dash::Autoscale::ReadOnlyQuery.within(postgres, deadline: 0.05) { postgres.exec("SELECT 1") }
    end
    assert_equal [ "BEGIN READ ONLY", "SET LOCAL statement_timeout = 5000", "SELECT 1" ], postgres.statements
  end

  test "the client deadline leaves the server's statement timeout room to answer first" do
    assert_operator Dash::Autoscale::ReadOnlyQuery::DEADLINE, :>, Dash::Autoscale::ReadOnlyQuery::STATEMENT_TIMEOUT_MS / 1000.0
  end
end
