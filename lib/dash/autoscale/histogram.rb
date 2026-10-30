# A window of request queue times as dash-proxy reports it per target (`list --json`,
# `target_details[].queue`): cumulative counts per finite upper bound in milliseconds, and
# the total, whose excess over the last bound is the +Inf bucket. Merging sums the counts,
# so the quantile of a merge is the fleet's, not an average of percentiles.
class Dash::Autoscale::Histogram
  attr_reader :buckets, :count

  # `buckets`: [ [ upper bound ms, cumulative count ], ... ] in ascending bound order.
  def initialize(buckets:, count:)
    @buckets, @count = buckets, count
  end

  def self.merge(histograms)
    return new(buckets: [], count: 0) if histograms.empty?

    bounds = histograms.first.bounds
    histograms.each do |histogram|
      next if histogram.bounds == bounds

      raise ArgumentError, "histograms with different bucket bounds cannot be merged: #{bounds} and #{histogram.bounds}"
    end

    counts = histograms.map { |histogram| histogram.buckets.map(&:last) }.transpose.map(&:sum)
    new(buckets: bounds.zip(counts), count: histograms.sum(&:count))
  end

  def bounds
    buckets.map(&:first)
  end

  # Prometheus' histogram_quantile, as dash-proxy computes its own p95: find the bucket the
  # rank falls in and interpolate linearly inside it. A rank past the last finite bound
  # reports that bound, there being nothing above it to interpolate towards.
  def quantile(q)
    return 0.0 if count.zero?

    rank = q * count
    lower_bound, lower_count = 0.0, 0

    buckets.each do |bound, cumulative|
      return lower_bound + (bound - lower_bound) * (rank - lower_count) / (cumulative - lower_count) if cumulative >= rank

      lower_bound, lower_count = bound.to_f, cumulative
    end

    lower_bound
  end
end
