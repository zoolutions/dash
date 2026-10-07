require "socket"

# A one-thread HTTP endpoint for Prometheus: `GET /metrics` answers the controller's
# Dash::Autoscale::Metrics, anything else is a 404. Binds 127.0.0.1 unless told otherwise
# (`--metrics-bind`), so the metrics are not on the network by accident. No gem: a scrape
# is one short request.
class Dash::Autoscale::MetricsServer
  READ_TIMEOUT = 5

  def initialize(metrics, bind:, port:)
    @metrics, @bind, @port = metrics, bind, port
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
    @thread&.join(READ_TIMEOUT)
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

    # One bad client never stops the endpoint.
    def answer(client)
      request = client.wait_readable(READ_TIMEOUT) && client.gets
      method, path = request.to_s.split(" ", 3)
      # The headers are read too: closing a socket with them unread resets the connection,
      # and a scraper can see the reset before the body.
      while client.wait_readable(READ_TIMEOUT) && (line = client.gets) && line != "\r\n" && line != "\n"; end

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
