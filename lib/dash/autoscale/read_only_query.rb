require "timeout"

# How the controller reads Postgres: inside a read-only transaction with a statement
# timeout, always rolled back, so a signal or guard query can neither write nor hang a tick.
# The statement timeout bounds the server; DEADLINE bounds the client, for a connection that
# stops answering at all (pg's `exec` waits on the socket in Ruby, so it can be interrupted).
module Dash::Autoscale::ReadOnlyQuery
  STATEMENT_TIMEOUT_MS = 5000
  DEADLINE = 10

  # The connection stopped answering. A Timeout::Error, so Dash::Autoscale::Connections
  # discards the connection - which ends its transaction on the server.
  class Stalled < Timeout::Error; end

  def self.within(connection, deadline: DEADLINE)
    Timeout.timeout(deadline, Stalled) do
      connection.exec("BEGIN READ ONLY")
      stalled = false
      begin
        connection.exec("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT_MS}")
        yield
      rescue Stalled
        stalled = true
        raise
      ensure
        # A ROLLBACK on a stalled socket would wait on it again, past the deadline.
        connection.exec("ROLLBACK") unless stalled
      end
    end
  end

  # The first column of the first row as a number; nil without a row or for SQL NULL.
  def self.number(connection, sql)
    result = connection.exec(sql)
    value = result.getvalue(0, 0) unless result.ntuples.zero?
    Float(value) unless value.nil?
  end
end
