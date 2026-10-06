# What every provider answers. `labels` is the role's membership:
# { "dash.service" => ..., "dash.destination" => ..., "dash.role" => ... }.
#
#   members(labels:, address:)              -> [ Member ] carrying exactly those labels
#   start(member)                           -> powers it on
#   stop(member, timeout:)                  -> powers it off, soft, within timeout seconds
#   create(labels:, template:, address:)    -> Member, the new server
#   destroy(member)                         -> deletes it and its storage
#   state(member)                           -> "started" | "stopped" | "maintenance" | "error"
#
# Every failure raises Dash::Autoscale::ProviderError.
class Dash::Autoscale::Provider::Base
  POLL_INTERVAL = 5

  def name
    self.class.name.demodulize.downcase
  end

  %i[ members start stop create destroy state ].each do |action|
    define_method(action) { |*, **| raise NotImplementedError, "#{self.class.name}##{action}" }
  end

  # Polls until the member reaches `state`, or raises once `timeout` seconds have passed.
  def wait_until(member, state:, timeout:, interval: POLL_INTERVAL)
    deadline = monotonic_now + timeout

    loop do
      current = state(member)
      return current if current == state

      if monotonic_now >= deadline
        raise Dash::Autoscale::ProviderError, "#{name}: #{member.id} is #{current}, not #{state}, after #{timeout}s"
      end

      sleep interval
    end
  end

  private
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
