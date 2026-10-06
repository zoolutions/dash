require "test_helper"

class CliScaleHostPlanTest < ActiveSupport::TestCase
  test "fills the hosts it has to their max before joining a member" do
    plan = plan(baseline: [ "b1" ], target: 3)

    assert_equal 0, plan.joins
    assert_equal({ "b1" => 3 }, plan.counts)
  end

  test "joins members once the active hosts are full, the baseline staying full" do
    plan = plan(baseline: [ "b1" ], target: 6)

    assert_equal 1, plan.joins
    assert_equal [ 3 ], plan.join_counts
    assert_equal({ "b1" => 3 }, plan.counts)
  end

  test "a joined member gets the remainder, never below min" do
    plan = plan(baseline: [ "b1" ], target: 4)

    assert_equal 1, plan.joins
    assert_equal [ 1 ], plan.join_counts

    plan = plan(baseline: [ "b1" ], target: 8, min: 2, max: 3, hosts_max: 4)
    assert_equal [ 3, 2 ], plan.join_counts
  end

  test "shrinks members before the baseline: a member ends at min while the baseline stays full" do
    plan = plan(baseline: [ "b1" ], members: [ "m1" ], target: 4)

    assert_empty plan.leaving
    assert_equal({ "b1" => 3, "m1" => 1 }, plan.counts)
  end

  test "a member leaves when the baseline alone holds the count, the last member first" do
    plan = plan(baseline: [ "b1" ], members: [ "m1", "m2" ], target: 3)

    assert_equal [ "m1", "m2" ], plan.leaving
    assert_equal({ "b1" => 3 }, plan.counts)

    plan = plan(baseline: [ "b1" ], members: [ "m1", "m2" ], target: 4)
    assert_equal [ "m2" ], plan.leaving
    assert_equal({ "b1" => 3, "m1" => 1 }, plan.counts)
  end

  test "the baseline sheds slots only once every member has left" do
    plan = plan(baseline: [ "b1", "b2" ], members: [ "m1" ], target: 2, hosts_min: 2)

    assert_equal [ "m1" ], plan.leaving
    assert_equal({ "b1" => 1, "b2" => 1 }, plan.counts)
  end

  test "scale min keeps members on even when the baseline could hold the count" do
    plan = plan(baseline: [ "b1" ], members: [ "m1" ], target: 2, hosts_min: 2)

    assert_empty plan.leaving
    assert_equal({ "b1" => 1, "m1" => 1 }, plan.counts)
  end

  test "a count the hosts cannot split within min and max is refused" do
    error = assert_raises(ArgumentError) { plan(baseline: [ "b1" ], target: 4, min: 3, max: 3) }

    assert_equal "4 containers cannot be split over 2 hosts with 3 to 3 per host", error.message
  end

  test "joins beyond scale max are refused" do
    error = assert_raises(ArgumentError) { plan(baseline: [ "b1" ], target: 7, hosts_max: 2) }

    assert_equal "7 containers need 3 hosts, scale max is 2", error.message
  end

  test "slot changes add the lowest free slots and remove the highest" do
    assert_equal [ [ 2, 4 ], [] ], Dash::Cli::Scale::HostPlan.slot_changes([ 1, 3 ], 4)
    assert_equal [ [], [ 3, 2 ] ], Dash::Cli::Scale::HostPlan.slot_changes([ 1, 2, 3 ], 1)
    assert_equal [ [], [] ], Dash::Cli::Scale::HostPlan.slot_changes([ 1, 2 ], 2)
  end

  private
    def plan(baseline:, target:, members: [], min: 1, max: 3, hosts_min: baseline.size, hosts_max: 3)
      Dash::Cli::Scale::HostPlan.new(baseline: baseline, members: members, target: target,
        replicas_min: min, replicas_max: max, hosts_min: hosts_min, hosts_max: hosts_max)
    end
end
