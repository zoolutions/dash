require "test_helper"

class CliScalePlacementTest < ActiveSupport::TestCase
  test "adds to the host with the fewest replicas, using the lowest free slot" do
    placement = placement({ "a" => [ 1 ], "b" => [ 1 ] }, target: 3)

    assert_equal({ "a" => [ 2 ] }, placement.additions)
    assert_equal({}, placement.removals)
  end

  test "spreads several additions evenly" do
    placement = placement({ "a" => [ 1 ], "b" => [ 1 ] }, target: 6)

    assert_equal({ "a" => [ 2, 3 ], "b" => [ 2, 3 ] }, placement.additions)
  end

  test "fills a gap left by a crashed slot first" do
    placement = placement({ "a" => [ 1, 3 ] }, target: 3)

    assert_equal({ "a" => [ 2 ] }, placement.additions)
  end

  test "removes from the host with the most replicas, highest slot first" do
    placement = placement({ "a" => [ 1, 2 ], "b" => [ 1, 2, 3 ] }, target: 4)

    assert_equal({ "b" => [ 3 ] }, placement.removals)
    assert_equal({}, placement.additions)
  end

  test "spreads several removals evenly" do
    placement = placement({ "a" => [ 1, 2, 3 ], "b" => [ 1, 2, 3 ] }, target: 2)

    assert_equal({ "a" => [ 3, 2 ], "b" => [ 3, 2 ] }, placement.removals)
  end

  test "changes nothing at the current count" do
    placement = placement({ "a" => [ 1, 2 ], "b" => [ 1 ] }, target: 3)

    assert_equal({}, placement.additions)
    assert_equal({}, placement.removals)
  end

  test "brings an empty host up to min before spreading" do
    placement = placement({ "a" => [ 1, 2 ], "b" => [] }, target: 3)

    assert_equal({ "b" => [ 1 ] }, placement.additions)
  end

  private
    def placement(running, target:, max: 3)
      Dash::Cli::Scale::Placement.new(running: running, target: target, max: max)
    end
end
