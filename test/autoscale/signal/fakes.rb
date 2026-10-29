# Stand-ins for the clients Dash::Autoscale::Connections hands the readers, recording what
# each was asked so a test can prove a reader stays read-only.
module AutoscaleSignalFakes
  class Connections
    attr_reader :clients, :closed

    def initialize(**clients)
      @clients = clients
    end

    def close
      @closed = true
    end

    def with(source)
      client = clients.fetch(source.to_sym)
      raise client if client.is_a?(Exception)

      yield client
    end
  end

  class Redis
    attr_reader :commands

    # `replies` maps a command (an array) to its reply, or to an exception to raise; any
    # other command raises.
    def initialize(replies = {})
      @replies = replies
      @commands = []
    end

    def call(*command)
      @commands << command
      reply = @replies.fetch(command) { raise KeyError, "unexpected command: #{command.inspect}" }
      raise reply if reply.is_a?(Exception)

      reply
    end
  end

  class Postgres
    Result = Struct.new(:rows) do
      def ntuples = rows.size
      def getvalue(row, column) = rows[row][column]
    end

    attr_reader :statements

    # `values` maps a SQL statement to the first column of its one row (nil: no row), or to
    # an exception to raise.
    def initialize(values = {})
      @values = values
      @statements = []
    end

    def exec(sql)
      @statements << sql
      return Result.new([]) if sql.start_with?("BEGIN", "SET LOCAL", "ROLLBACK")

      value = @values.fetch(sql) { raise KeyError, "unexpected SQL: #{sql}" }
      raise value if value.is_a?(Exception)

      Result.new(value.nil? ? [] : [ [ value ] ])
    end

    def quote_ident(name)
      %("#{name.gsub('"', '""')}")
    end
  end

  class Prometheus
    attr_reader :queries

    def initialize(values = {})
      @values = values
      @queries = []
    end

    def query(promql)
      @queries << promql
      value = @values.fetch(promql)
      raise value if value.is_a?(Exception)

      value
    end
  end
end
