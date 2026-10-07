require "test_helper"

class ConfigurationRoleScaleWindowTest < ActiveSupport::TestCase
  test "active from the matching minute for its duration" do
    window = window("0 22 14 * *", 30 * 3600)

    assert_not window.active_at?(utc("2026-10-14 21:59"))
    assert window.active_at?(utc("2026-10-14 22:00"))
    assert window.active_at?(utc("2026-10-15 12:00")), "across midnight"
    assert window.active_at?(utc("2026-10-16 03:59:59"))
    assert_not window.active_at?(utc("2026-10-16 04:00"))
  end

  test "the start and end of the window it is in" do
    window = window("0 22 14 * *", 3600)

    assert_equal utc("2026-10-14 22:00"), window.started_at(utc("2026-10-14 22:30"))
    assert_equal utc("2026-10-14 23:00"), window.ends_at(utc("2026-10-14 22:30"))
    assert_nil window.started_at(utc("2026-10-14 23:00"))
    assert_nil window.ends_at(utc("2026-10-14 23:00"))
  end

  test "the latest match wins when matches overlap" do
    window = window("0 * * * *", 2 * 3600)

    assert_equal utc("2026-10-14 05:00"), window.started_at(utc("2026-10-14 05:10"))
  end

  test "across a month end" do
    window = window("0 22 28-31 * *", 30 * 3600)

    assert window.active_at?(utc("2026-11-01 03:00")), "started on the 31st of October"
    assert window.active_at?(utc("2026-03-01 03:00")), "started on the 28th of February"
  end

  test "wall-clock in its zone, for its real duration across a DST change" do
    stockholm = ActiveSupport::TimeZone["Europe/Stockholm"]
    window = window("0 1 * * *", 4 * 3600)

    # 2026-10-25 03:00 CEST becomes 02:00 CET: 01:00 + 4 real hours is 04:00 CET.
    assert window.active_at?(stockholm.parse("2026-10-25 03:59"))
    assert_not window.active_at?(stockholm.parse("2026-10-25 04:00"))
    assert_equal stockholm.parse("2026-10-25 04:00"), window.ends_at(stockholm.parse("2026-10-25 02:30"))
  end

  test "a wall-clock minute a spring-forward skips never matches" do
    stockholm = ActiveSupport::TimeZone["Europe/Stockholm"]
    window = window("30 2 29 3 *", 3600)

    # 2026-03-29 02:00 CET jumps to 03:00 CEST: 02:30 does not exist that day.
    assert_not window.active_at?(stockholm.parse("2026-03-29 03:15"))
  end

  test "to_h names the cron, the duration and the floor" do
    assert_equal({ cron: "0 22 14 * *", for: 3600, min: 10 }, window("0 22 14 * *", 3600).to_h)
  end

  private
    def window(cron, duration, min: 10)
      Dash::Configuration::Role::Scale::Window.new(cron: Dash::Autoscale::Cron.parse(cron), duration: duration, min: min)
    end

    def utc(time)
      ActiveSupport::TimeZone["UTC"].parse(time)
    end
end
