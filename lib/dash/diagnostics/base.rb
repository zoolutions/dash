require "dash/sshkit_with_ext"

# What every diagnostic shares: a JSON-safe `to_h` stamped with when it was taken, and
# per-host isolation. A host that cannot be reached, or answers with something that does
# not parse, becomes `{ host:, error: }` in the snapshot - a debugging tool that dies on
# the broken host is useless exactly when it is needed (same contract as Dash::Diagnostics::Doctor).
#
# Read-only by contract: a diagnostic only ever captures, never takes the deploy lock,
# never writes an audit line, never fires a hook. The pre-connect hook is the caller's
# (the CLI command or `dash mcp` at boot), as with Doctor.
class Dash::Diagnostics::Base
  include SSHKit::DSL

  def to_h
    { generated_at: Time.now.utc.iso8601 }.merge(snapshot)
  end

  private
    def snapshot
      raise NotImplementedError
    end

    # [ { host:, **yield } | { host:, error: } ] in the order the hosts were given. The
    # block runs inside each host's SSHKit backend and gets it as its argument.
    #
    # StandardError rather than the SSHKit errors alone, deliberately: a failed connection
    # raises anything from Net::SSH errors to Errno and DNS resolution errors, and none of
    # them may take the other hosts' answers down with them.
    def per_host(hosts, &block)
      results = {}
      mutex = Mutex.new

      on(hosts) do |host|
        result = begin
          block.call(self, host.to_s)
        rescue StandardError => e
          { error: "#{e.class}: #{e.message}" }
        end

        mutex.synchronize { results[host.to_s] = result }
      end

      hosts.map { |host| { host: host.to_s }.merge(results.fetch(host.to_s) { { error: "no answer" } }) }
    end
end
