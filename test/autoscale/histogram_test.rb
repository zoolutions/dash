require "test_helper"

class AutoscaleHistogramTest < ActiveSupport::TestCase
  BOUNDS = [ 10, 25, 50, 100 ]

  test "the quantile interpolates inside the bucket the rank falls in, as Prometheus does" do
    # 100 requests: 40 up to 10ms, 40 more up to 25ms, 20 more up to 50ms.
    histogram = histogram([ 40, 80, 100, 100 ], count: 100)

    assert_equal 100, histogram.count
    assert_in_delta 43.75, histogram.quantile(0.95), 1e-9 # rank 95 is 15 of 20 into (25, 50]
    assert_in_delta 5.0, histogram.quantile(0.2), 1e-9    # rank 20 is half of (0, 10]
  end

  test "a rank past the last finite bound reports that bound" do
    # 10 requests, 4 of them slower than 100ms.
    assert_equal 100.0, histogram([ 2, 4, 6, 6 ], count: 10).quantile(0.95)
  end

  test "no requests is zero" do
    histogram = histogram([ 0, 0, 0, 0 ], count: 0)

    assert_equal 0, histogram.count
    assert_equal 0.0, histogram.quantile(0.95)
  end

  test "merging sums each bound's count and the totals, so the quantile is the fleet's" do
    fast = histogram([ 10, 10, 10, 10 ], count: 10)  # every request under 10ms
    slow = histogram([ 0, 0, 0, 10 ], count: 10)     # every request in (50, 100]
    merged = Dash::Autoscale::Histogram.merge([ fast, slow ])

    assert_equal 20, merged.count
    assert_in_delta 95.0, merged.quantile(0.95), 1e-9 # rank 19 is 9 of 10 into (50, 100]
    assert_in_delta 10.0, merged.quantile(0.5), 1e-9
  end

  test "merging nothing is an empty histogram" do
    merged = Dash::Autoscale::Histogram.merge([])

    assert_equal 0, merged.count
    assert_equal 0.0, merged.quantile(0.95)
  end

  test "histograms with different bounds do not merge" do
    other = Dash::Autoscale::Histogram.new(buckets: [ [ 5, 1 ] ], count: 1)

    error = assert_raises(ArgumentError) { Dash::Autoscale::Histogram.merge([ histogram([ 1, 1, 1, 1 ], count: 1), other ]) }
    assert_equal "histograms with different bucket bounds cannot be merged: [10, 25, 50, 100] and [5]", error.message
  end

  private
    def histogram(cumulative, count:)
      Dash::Autoscale::Histogram.new(buckets: BOUNDS.zip(cumulative), count: count)
    end
end
