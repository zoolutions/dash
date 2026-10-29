# The age in seconds of the oldest claimable message across the role's queues. A pgbus queue
# `<name>` is the pgmq table `pgmq.q_<prefix><name>`; a message is claimable once its
# visibility time `vt` has passed, so scheduled messages do not count (pgmq.metrics()'s
# oldest_msg_age_sec does count them). pgbus reports no jobs in progress, so a pgbus role
# drains on `docker stop` alone.
class Dash::Autoscale::Signal::Pgbus < Dash::Autoscale::Signal
  private
    def read(_at)
      connections.with(:postgres) do |postgres|
        Dash::Autoscale::ReadOnlyQuery.within(postgres) do
          config.queues.map { |queue| Dash::Autoscale::ReadOnlyQuery.number(postgres, claimable_age(postgres, queue)) || 0 }.max
        end
      end
    end

    def claimable_age(postgres, queue)
      "SELECT EXTRACT(epoch FROM now() - min(vt)) FROM pgmq.#{postgres.quote_ident("q_#{config.prefix}#{queue}")} WHERE vt <= now()"
    end
end
