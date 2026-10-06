require "test_helper"

class DiagnosticsUnitsTest < ActiveSupport::TestCase
  test "bytes reads docker's binary units, as MemUsage prints them" do
    assert_equal 120 * 1024**2, Dash::Diagnostics::Units.bytes("120MiB")
    assert_equal (1.9 * 1024**3).round, Dash::Diagnostics::Units.bytes("1.9GiB")
    assert_equal 512 * 1024, Dash::Diagnostics::Units.bytes("512KiB")
  end

  test "bytes reads docker's decimal units, as NetIO and BlockIO print them" do
    assert_equal 1_200, Dash::Diagnostics::Units.bytes("1.2kB")
    assert_equal 3_400_000, Dash::Diagnostics::Units.bytes("3.4MB")
    assert_equal 2_000_000_000, Dash::Diagnostics::Units.bytes("2GB")
    assert_equal 0, Dash::Diagnostics::Units.bytes("0B")
  end

  test "bytes is nil for what it cannot read, so the raw value is all that is left" do
    assert_nil Dash::Diagnostics::Units.bytes("--")
    assert_nil Dash::Diagnostics::Units.bytes(nil)
    assert_nil Dash::Diagnostics::Units.bytes("12 parsecs")
    assert_nil Dash::Diagnostics::Units.bytes("12kiB")
  end

  test "a pair splits on the slash" do
    assert_equal [ 120 * 1024**2, (1.9 * 1024**3).round ], Dash::Diagnostics::Units.pair("120MiB / 1.9GiB")
    assert_equal [ 1_200, 0 ], Dash::Diagnostics::Units.pair("1.2kB / 0B")
    assert_equal [ nil, nil ], Dash::Diagnostics::Units.pair("--")
  end

  test "percent" do
    assert_equal 1.23, Dash::Diagnostics::Units.percent("1.23%")
    assert_equal 0.0, Dash::Diagnostics::Units.percent("0.00%")
    assert_nil Dash::Diagnostics::Units.percent("--")
    assert_nil Dash::Diagnostics::Units.percent("NaN%")
    assert_nil Dash::Diagnostics::Units.percent("Infinity%")
  end
end
