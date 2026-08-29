# Wall-clock accounting for a deploy, printed under "Finished all in". The total on its
# own says nothing about where the time went — a serialised boot, a slow pull, or a proxy
# waiting on a health check all look the same from the outside.
#
# Entries land in start order and carry a depth, so a parent phase (Boot) prints above
# the host entries it wraps even though the hosts finish first. Boot runs one thread per
# host, so every mutation is behind the mutex.
class Dash::Timings
  Entry = Struct.new(:name, :seconds, :detail, :depth)

  def initialize
    @entries = []
    @mutex = Mutex.new
  end

  # Times the block. The entry is yielded so the block can annotate it — a boot can say
  # how long of its total was spent waiting for the container to become healthy.
  def phase(name, depth: 0)
    entry = Entry.new(name, nil, nil, depth)
    @mutex.synchronize { @entries << entry }
    started = clock

    yield entry
  ensure
    entry.seconds = clock - started
  end

  def any?
    @mutex.synchronize { @entries.any? }
  end

  def lines
    @mutex.synchronize do
      @entries.map do |entry|
        line = format("  %s%-36s %6.1fs", "  " * entry.depth, entry.name, entry.seconds.to_f)
        entry.detail ? "#{line} (#{entry.detail})" : line
      end
    end
  end

  private
    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
