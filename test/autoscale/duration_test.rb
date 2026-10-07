require "test_helper"

class AutoscaleDurationTest < ActiveSupport::TestCase
  test "an integer is seconds" do
    assert_equal 300, Dash::Autoscale::Duration.parse(300)
    assert_equal 0, Dash::Autoscale::Duration.parse(0)
  end

  test "a string takes s, m, h or d, or no unit for seconds" do
    assert_equal 45, Dash::Autoscale::Duration.parse("45")
    assert_equal 45, Dash::Autoscale::Duration.parse("45s")
    assert_equal 900, Dash::Autoscale::Duration.parse("15m")
    assert_equal 108_000, Dash::Autoscale::Duration.parse("30h")
    assert_equal 604_800, Dash::Autoscale::Duration.parse("7d")
  end

  test "anything else is an error naming the accepted forms" do
    [ "2w", "1.5h", "-3", "", "h", nil, -1, 1.5, [] ].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { Dash::Autoscale::Duration.parse(value) }
      assert_match "should be seconds, or a number followed by s, m, h or d", error.message
    end
  end
end
