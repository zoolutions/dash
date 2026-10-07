require "test_helper"

class AutoscaleLeaseTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 14, 22, 0, 0)

  test "no heartbeat is no lease" do
    lease = Dash::Autoscale::Lease.new({}, now: NOW)

    assert_not lease.alive?
    assert_not lease.held_by_another?("me")
  end

  test "a heartbeat within three of its own intervals is alive" do
    lease = Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW - 29, interval: 10), now: NOW)

    assert lease.alive?
    assert_equal 29, lease.age
    assert lease.held_by_another?("me")
    assert_not lease.held_by_another?("abc")
  end

  test "a heartbeat older than three of its intervals is stale" do
    assert_not Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW - 31, interval: 10), now: NOW).alive?
    assert Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW - 89, interval: 30), now: NOW).alive?
  end

  test "a heartbeat from the future is believed only as far ahead as an old one would be" do
    assert Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW + 29, interval: 10), now: NOW).alive?
    assert_not Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW + 3600, interval: 10), now: NOW).alive?
  end

  test "a controller that stopped holds nothing" do
    assert_not Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW - 1, stopped_at: (NOW - 1).iso8601), now: NOW).alive?
  end

  test "a heartbeat with a time that does not parse is stale" do
    assert_not Dash::Autoscale::Lease.new(heartbeat(last_tick_at: "never"), now: NOW).alive?
  end

  test "describes who holds it" do
    lease = Dash::Autoscale::Lease.new(heartbeat(last_tick_at: NOW - 12), now: NOW)

    assert_equal "controller abc on ops-1 (pid 42, dash 3.9.0), last tick 12s ago", lease.describe
  end

  private
    def heartbeat(last_tick_at:, interval: 10, **extra)
      { "controller_id" => "abc", "hostname" => "ops-1", "pid" => 42, "version" => "3.9.0", "interval" => interval,
        "last_tick_at" => last_tick_at.is_a?(Time) ? last_tick_at.iso8601 : last_tick_at }.merge(extra.transform_keys(&:to_s))
    end
end
