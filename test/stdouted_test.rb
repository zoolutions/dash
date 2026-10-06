require "test_helper"

# `stdouted` is how every CLI test reads what a command printed, and a command prints
# from one SSHKit thread per host. Buffered writes to the same IO from several threads
# lose lines on MRI - a burst from one thread drops a line another wrote (#176: a spinning
# readiness poll on one worker host swallowed the other host's "ERROR Failed to boot").
class StdoutedTest < ActiveSupport::TestCase
  test "keeps every line written concurrently from several threads" do
    output = stdouted do
      noisy = Thread.new { 20_000.times { |i| $stdout << "spin #{i} #{"x" * 150}\n" } }
      quiet = Thread.new { 500.times { |i| $stdout << "marker #{i}\n"; Thread.pass } }
      [ noisy, quiet ].each(&:join)
    end

    assert_equal 500, output.scan(/^marker \d+$/).size
    assert_equal 20_000, output.scan(/^spin \d+ x+$/).size
  end
end
