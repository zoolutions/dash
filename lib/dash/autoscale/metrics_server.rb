require "socket"

# A one-thread HTTP endpoint for Prometheus: `GET /metrics` answers the controller's
# Dash::Autoscale::Metrics, anything else is a 404. Binds 127.0.0.1 unless told otherwise
# (`--metrics-bind`), so the metrics are not on the network by accident. No gem: a scrape
# is one short request.
class Dash::Autoscale::MetricsServer
  READ_TIMEOUT = 5
  MAX_HEADER_LINES = 100

  def initialize(metrics, bind:, port:, timeout: READ_TIMEOUT)
    @metrics, @bind, @port, @timeout = metrics, bind, port, timeout
  end

  def start
    @server = TCPServer.new(@bind, @port)
    @thread = Thread.new { serve }
    self
  end

  def port
    @server.addr[1]
  end

  def stop
    @server&.close
    @thread&.join(@timeout)
  rescue IOError
    nil
  end

  private
    def serve
      loop do
        client = @server.accept
        answer(client)
      end
    rescue IOError, Errno::EBADF
      # Closed by #stop.
    end

    # One bad client never stops the endpoint: every read times out (IO::TimeoutError), and a
    # request gets READ_TIMEOUT and MAX_HEADER_LINES in all, so a slow drip cannot hold it.
    def answer(client)
      client.timeout = @timeout
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      method, path = client.gets.to_s.split(" ", 3)
      # The headers are read too: closing a socket with them unread resets the connection,
      # and a scraper can see the reset before the body.
      MAX_HEADER_LINES.times do
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        line = client.gets
        break if line.nil? || line.strip.empty?
      end

      if method == "GET" && path == "/metrics"
        respond client, "200 OK", @metrics.render
      else
        respond client, "404 Not Found", "Not found\n"
      end
    rescue StandardError
      nil
    ensure
      client.close
    end

    def respond(client, status, body)
      client.write "HTTP/1.1 #{status}\r\nContent-Type: #{Dash::Autoscale::Metrics::CONTENT_TYPE}\r\n" \
        "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end
end
