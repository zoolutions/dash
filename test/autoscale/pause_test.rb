require "test_helper"

class AutoscalePauseTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 14, 22, 0)

  test "no pause file is no pause" do
    assert_nil Dash::Autoscale::Pause.from(nil)
  end

  test "an indefinite pause" do
    pause = Dash::Autoscale::Pause.from("until" => "indefinite", "by" => "Jane", "at" => "2026-10-14T21:00:00Z")

    assert_equal :indefinite, pause.ends_at
    assert pause.active?(NOW)
    assert_equal "Jane", pause.by
    assert_equal Time.utc(2026, 10, 14, 21), pause.at
  end

  test "a pause until a time is active before it and not after" do
    pause = Dash::Autoscale::Pause.from("until" => "2026-10-14T23:00:00Z")

    assert_equal Time.utc(2026, 10, 14, 23), pause.ends_at
    assert pause.active?(NOW)
    assert_not pause.active?(NOW + 3600)
  end

  test "a pause whose until does not parse holds indefinitely rather than letting go" do
    assert_equal :indefinite, Dash::Autoscale::Pause.from("until" => "soon").ends_at
  end

  test "builds a pause for a duration, and writes it as JSON" do
    pause = Dash::Autoscale::Pause.new(ends_at: NOW + 7200, by: "Jane", at: NOW)

    assert_equal({ "until" => "2026-10-15T00:00:00Z", "by" => "Jane", "at" => "2026-10-14T22:00:00Z" }, pause.to_h)
    assert_equal({ "until" => "indefinite", "by" => "Jane", "at" => "2026-10-14T22:00:00Z" }, Dash::Autoscale::Pause.new(ends_at: :indefinite, by: "Jane", at: NOW).to_h)
  end
end
