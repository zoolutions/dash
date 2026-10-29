# How the controller reads Postgres: inside a read-only transaction with a statement
# timeout, always rolled back, so a signal or guard query can neither write nor hang a tick.
module Dash::Autoscale::ReadOnlyQuery
  STATEMENT_TIMEOUT_MS = 5000

  def self.within(connection)
    connection.exec("BEGIN READ ONLY")
    begin
      connection.exec("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT_MS}")
      yield
    ensure
      connection.exec("ROLLBACK")
    end
  end

  # The first column of the first row as a number; nil without a row or for SQL NULL.
  def self.number(connection, sql)
    result = connection.exec(sql)
    value = result.getvalue(0, 0) unless result.ntuples.zero?
    Float(value) unless value.nil?
  end
end
