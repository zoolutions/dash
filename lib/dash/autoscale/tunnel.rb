require "net/ssh"

# A local port forwarded over SSH through a `via` host to a database or Prometheus only the
# app servers can reach. Its own Net::SSH session and event-loop thread - never one of
# SSHKit's pooled connections, which nothing keeps looping - on 127.0.0.1 and an ephemeral
# port net-ssh picks and returns.
class Dash::Autoscale::Tunnel
  ADDRESS = "127.0.0.1"
  LOOP_WAIT = 0.1
  CLOSE_WAIT = 2

  attr_reader :port

  def self.open(via, host, port, ssh: DASH.config.ssh)
    new(via, host, port, user: ssh.user, ssh_options: ssh.options.except(:user))
  end

  def initialize(via, host, port, user:, ssh_options:, starter: ->(server, login, **options) { Net::SSH.start(server, login, options) })
    @session = starter.call(via, user, **ssh_options)
    begin
      @port = @session.forward.local(ADDRESS, 0, host, port)
    rescue StandardError
      @session.close
      raise
    end
    @closing = false
    @thread = Thread.new { @session.loop(LOOP_WAIT) { !@closing } }
    @thread.report_on_exception = false
  end

  def address
    ADDRESS
  end

  # False once the session dropped: the client it carried has nothing to connect to.
  def alive?
    @thread.alive?
  end

  def close
    @closing = true
    @thread.join(CLOSE_WAIT)
    @session.forward.cancel_local(port, ADDRESS)
    @session.close
  rescue IOError, Net::SSH::Exception
    nil # the session is gone already
  end
end
