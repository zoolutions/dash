require "test_helper"
require "net/http"

class AutoscaleMetricsServerTest < ActiveSupport::TestCase
  setup do
    @metrics = Dash::Autoscale::Metrics.new
    @server = Dash::Autoscale::MetricsServer.new(@metrics, bind: "127.0.0.1", port: 0).start
  end

  teardown do
    @server.stop
  end

  test "answers GET /metrics with the Prometheus text" do
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server.port}/metrics"))

    assert_equal "200", response.code
    assert_equal "text/plain; version=0.0.4; charset=utf-8", response["Content-Type"]
    assert_equal @metrics.render, response.body
  end

  test "reads the request's headers before answering, as a scraper sends them" do
    socket = TCPSocket.new("127.0.0.1", @server.port)
    socket.write "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: Prometheus/2.53\r\nAccept: text/plain\r\n\r\n"
    response = socket.read

    assert_match "HTTP/1.1 200 OK", response
    assert response.end_with?(@metrics.render)
  ensure
    socket&.close
  end

  test "anything else is a 404" do
    assert_equal "404", Net::HTTP.get_response(URI("http://127.0.0.1:#{@server.port}/")).code
  end

  test "stops listening when stopped" do
    port = @server.port
    @server.stop

    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", port) }
  end
end
