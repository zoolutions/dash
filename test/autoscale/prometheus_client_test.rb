require "test_helper"
require "net/http"

class AutoscalePrometheusClientTest < ActiveSupport::TestCase
  test "an instant query: the largest value of a vector" do
    request = stub_response(200, vector("1.5", "7.25"))

    assert_equal 7.25, client.query(%(max(lag{queue="billing"})))
    assert_equal "/api/v1/query?query=max%28lag%7Bqueue%3D%22billing%22%7D%29", request.call.path
    assert_nil request.call["Authorization"]
  end

  test "a scalar is its value" do
    stub_response(200, { status: "success", data: { resultType: "scalar", result: [ 1_700_000_000, "3" ] } })

    assert_equal 3.0, client.query("scalar(x)")
  end

  test "no series is nil; NaN or an infinite series is NaN, which a sample reads as missing" do
    stub_response(200, vector)
    assert_nil client.query("x")

    stub_response(200, vector("NaN"))
    assert client.query("x").nan?

    stub_response(200, vector("4", "+Inf"))
    assert client.query("x").nan?
  end

  test "sends the bearer token, keeps a path prefix" do
    request = stub_response(200, vector("1"))
    Dash::Autoscale::PrometheusClient.new(url: "https://metrics.internal/prometheus/", token: "t0k3n").query("x")

    assert_equal "Bearer t0k3n", request.call["Authorization"]
    assert_equal "/prometheus/api/v1/query?query=x", request.call.path
  end

  test "an HTTP error or an error status raises" do
    stub_response(503, "unavailable")
    assert_raises(Dash::Autoscale::PrometheusClient::Error) { client.query("x") }

    stub_response(400, { status: "error", errorType: "bad_data", error: "parse error" })
    error = assert_raises(Dash::Autoscale::PrometheusClient::Error) { client.query("x(") }
    assert_match "parse error", error.message
  end

  test "through a tunnel it connects to the tunnel while TLS still names the host" do
    http = Net::HTTP.new("metrics.internal", 443)
    Net::HTTP.expects(:new).with("metrics.internal", 54_321).returns(http)
    stub_response(200, vector("1"))

    Dash::Autoscale::PrometheusClient.new(url: "https://metrics.internal", tunnel: stub(address: "127.0.0.1", port: 54_321)).query("x")

    assert_equal "127.0.0.1", http.ipaddr
    assert http.use_ssl?
  end

  private
    def client
      Dash::Autoscale::PrometheusClient.new(url: "http://10.0.0.9:9090")
    end

    def vector(*values)
      { status: "success", data: { resultType: "vector", result: values.map { |value| { metric: {}, value: [ 1_700_000_000, value ] } } } }
    end

    # Answers the next request with `body`; returns a proc giving the request it received.
    def stub_response(code, body)
      received = nil
      response = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new("1.1", code.to_s, "")
      response.stubs(:body).returns(body.is_a?(String) ? body : JSON.generate(body))
      Net::HTTP.any_instance.stubs(:request).with { |request| received = request }.returns(response)
      -> { received }
    end
end
