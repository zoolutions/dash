require "test_helper"

class ConfigurationRoleScaleGuardTest < ActiveSupport::TestCase
  test "a query, the source it runs on and the bound it holds above" do
    guard = guard("source" => "postgres", "query" => "SELECT count(*) FROM pg_stat_activity", "above" => 180)

    assert_equal "postgres", guard.source
    assert_equal "SELECT count(*) FROM pg_stat_activity", guard.query
    assert_equal 180, guard.above
    assert_equal "postgres", guard.connection
    assert_equal({ source: "postgres", query: "SELECT count(*) FROM pg_stat_activity", above: 180 }, guard.to_h)
  end

  test "a prometheus guard reads through the prometheus connection" do
    assert_equal "prometheus", guard("source" => "prometheus", "query" => "max(x)", "above" => 0.5).connection
  end

  test "a bound is a number" do
    error = assert_raises(Dash::ConfigurationError) { guard("source" => "prometheus", "query" => "max(x)", "above" => "0") }
    assert_match %r{servers/workers/scale/hold_when/0/above: should be a finite number}, error.message
  end

  test "a bound that no reading can pass (NaN, infinity) is refused" do
    [ Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |above|
      error = assert_raises(Dash::ConfigurationError, above.inspect) { guard("source" => "postgres", "query" => "SELECT 1", "above" => above) }
      assert_match %r{hold_when/0/above: should be a finite number}, error.message
    end
  end

  private
    def guard(config)
      Dash::Configuration::Role::Scale::Guard.new(guard_config: config, context: "servers/workers/scale/hold_when/0")
    end
end
