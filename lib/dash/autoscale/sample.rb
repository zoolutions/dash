# One reading of a signal or a guard: the number, when it was read, or the error that kept
# it from being read. A reader never raises out of a tick - a failure is a Sample with an
# error, and the policy holds the role with `missing_data`.
#
# `detail` is what a source can say about how it got the number (the proxy signal: the
# unit, the window, which hosts answered); it rides along in `to_h`, so a decision, a
# record and `dash autoscale signal --json` carry it.
Dash::Autoscale::Sample = Struct.new(:value, :at, :error, :detail, keyword_init: true) do
  # No number to act on: an error, nothing read, or a NaN/Inf a query returned.
  def missing?
    !error.nil? || !value.is_a?(Numeric) || (value.is_a?(Float) && !value.finite?)
  end

  def to_h
    hash = { value: (value unless missing?), at: at, error: error.respond_to?(:message) ? error.message : error }
    detail.nil? ? hash : hash.merge(detail: detail)
  end
end
