require "test_helper"

class AutoscaleCronTest < ActiveSupport::TestCase
  test "every field a star matches every minute" do
    assert cron("* * * * *").match?(at("2026-10-06 13:37"))
  end

  test "single values, lists and ranges" do
    schedule = cron("0,30 9-17 * * *")

    assert schedule.match?(at("2026-10-06 09:00"))
    assert schedule.match?(at("2026-10-06 17:30"))
    assert_not schedule.match?(at("2026-10-06 18:00"))
    assert_not schedule.match?(at("2026-10-06 09:15"))
  end

  test "steps over a star and over a range" do
    assert cron("*/15 * * * *").match?(at("2026-10-06 10:45"))
    assert_not cron("*/15 * * * *").match?(at("2026-10-06 10:50"))

    schedule = cron("10-40/10 * * * *")
    assert_equal [ 10, 20, 30, 40 ], (0..59).select { |minute| schedule.match?(at(format("2026-10-06 10:%02d", minute))) }
  end

  test "the month field" do
    assert cron("0 0 1 1-3 *").match?(at("2026-02-01 00:00"))
    assert_not cron("0 0 1 1-3 *").match?(at("2026-04-01 00:00"))
  end

  test "Sunday is 0 and 7" do
    sunday = at("2026-10-04 12:00")

    assert cron("0 12 * * 0").match?(sunday)
    assert cron("0 12 * * 7").match?(sunday)
    assert cron("0 12 * * 5-7").match?(sunday)
    assert_not cron("0 12 * * 1-5").match?(sunday)
  end

  test "day-of-month and day-of-week both restricted: either one matches (Vixie)" do
    schedule = cron("0 0 1,15 * 1")

    assert schedule.match?(at("2026-10-01 00:00")), "the 1st, a Thursday"
    assert schedule.match?(at("2026-10-05 00:00")), "a Monday, the 5th"
    assert_not schedule.match?(at("2026-10-06 00:00"))
  end

  test "only one day field restricted: it alone decides" do
    assert_not cron("0 0 1 * *").match?(at("2026-10-05 00:00"))
    assert_not cron("0 0 * * 1").match?(at("2026-10-01 00:00"))
    assert cron("0 0 */2 * 1").match?(at("2026-10-05 00:00")), "a starred step leaves the field unrestricted"
  end

  test "keeps its expression" do
    assert_equal "0 22 14,28-31 * *", cron("0 22 14,28-31 * *").to_s
  end

  test "five fields, no more and no less" do
    assert_error(/has 4 fields, a cron has 5 \(minute hour day-of-month month day-of-week\)/) { cron("0 0 * *") }
    assert_error(/has 6 fields/) { cron("0 0 * * * 2026") }
  end

  test "values out of range name the field" do
    assert_error(/minute: 60 is outside 0-59/) { cron("60 * * * *") }
    assert_error(/hour: 24 is outside 0-23/) { cron("0 24 * * *") }
    assert_error(/day-of-month: 0 is outside 1-31/) { cron("0 0 0 * *") }
    assert_error(/month: 13 is outside 1-12/) { cron("0 0 * 13 *") }
    assert_error(/day-of-week: 8 is outside 0-7/) { cron("0 0 * * 8") }
  end

  test "reversed ranges and zero steps are errors" do
    assert_error(/hour: 17-9 is a reversed range/) { cron("0 17-9 * * *") }
    assert_error(/minute: \*\/0 needs a step of at least 1/) { cron("*/0 * * * *") }
  end

  test "names, L, W and # are not supported" do
    [ [ "0 0 L * *", "day-of-month", "L" ], [ "0 0 15W * *", "day-of-month", "15W" ],
      [ "0 0 * * MON", "day-of-week", "MON" ], [ "0 0 * * 1#2", "day-of-week", "1#2" ],
      [ "0 0 * JAN *", "month", "JAN" ], [ "0 0 5/2 * *", "day-of-month", "5/2" ] ].each do |expression, field, value|
      assert_error(/#{field}: #{Regexp.escape(value)} is not supported, use numbers, \*, ranges \(a-b\), lists \(a,b\) and steps \(\*\/n, a-b\/n\)/) { cron(expression) }
    end
  end

  private
    def cron(expression)
      Dash::Autoscale::Cron.parse(expression)
    end

    def at(time)
      ActiveSupport::TimeZone["UTC"].parse(time)
    end

    def assert_error(pattern, &block)
      error = assert_raises(Dash::Autoscale::Cron::Error, &block)
      assert_match pattern, error.message
    end
end
