require "json"

# The age in seconds of the oldest job waiting across the role's queues. A Sidekiq queue is
# the Redis list `queue:<name>`, pushed on the left and fetched from the right, so its
# oldest job is `LINDEX queue:<name> -1`. Sidekiq 7 and older write `enqueued_at` as float
# epoch seconds, Sidekiq 8 as integer epoch milliseconds. Reads only: LINDEX, SMEMBERS, HMGET.
class Dash::Autoscale::Signal::Sidekiq < Dash::Autoscale::Signal
  # Epoch seconds pass this in the year 5138; epoch milliseconds passed it in 1973.
  MILLISECONDS_ABOVE = 1e11

  def busy?
    true
  end

  # Jobs in progress in the containers whose hostnames are given: Sidekiq reports each
  # process's `hostname` (the container's) in its `info` and its jobs in progress in `busy`.
  def busy(hostnames)
    connections.with(:redis) do |redis|
      Array(redis.call("SMEMBERS", "processes")).sum do |identity|
        info, busy = redis.call("HMGET", identity, "info", "busy")
        info && hostnames.include?(JSON.parse(info)["hostname"]) ? busy.to_i : 0
      end
    end
  end

  private
    def read(at)
      connections.with(:redis) do |redis|
        config.queues.map { |queue| age(redis.call("LINDEX", "queue:#{queue}", -1), at) }.max
      end
    end

    def age(job, at)
      return 0 if job.nil?

      enqueued_at = JSON.parse(job).fetch("enqueued_at")
      enqueued_at /= 1000.0 if enqueued_at > MILLISECONDS_ABOVE
      [ at.to_f - enqueued_at, 0 ].max
    end
end
