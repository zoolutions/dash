require "json"
require "net/http"
require "uri"

# Prometheus's instant query API over Net::HTTP, as the gem's other HTTP client
# (Dash::OtelShipper) uses it. A vector reads as its largest value, a scalar as its value;
# no series is nil, and a NaN or infinite series NaN - both a missing sample. Through a
# tunnel it connects to the tunnel (`ipaddr`) while TLS still names the URL's host.
class Dash::Autoscale::PrometheusClient
  class Error < StandardError; end

  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  def initialize(url:, token: nil, tunnel: nil)
    @uri = URI(url.end_with?("/") ? url : "#{url}/")
    @token, @tunnel = token, tunnel
  end

  def query(promql)
    uri = URI.join(@uri, "api/v1/query")
    uri.query = URI.encode_www_form(query: promql)
    request = Net::HTTP::Get.new(uri.request_uri)
    request["Authorization"] = "Bearer #{@token}" if @token

    value(data(http.request(request)))
  end

  # Nothing held open between queries.
  def close; end

  private
    def http
      Net::HTTP.new(@uri.host, @tunnel ? @tunnel.port : @uri.port).tap do |http|
        http.ipaddr = @tunnel.address if @tunnel
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
      end
    end

    def data(response)
      body = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        nil
      end

      return body["data"] if response.is_a?(Net::HTTPSuccess) && body.is_a?(Hash) && body["status"] == "success"

      raise Error, "Prometheus answered HTTP #{response.code}#{": #{body["error"]}" if body.is_a?(Hash) && body["error"]}"
    end

    def value(data)
      case data["resultType"]
      when "vector"
        values = data["result"].map { |series| number(series["value"][1]) }
        return if values.empty?

        values.all?(&:finite?) ? values.max : Float::NAN
      when "scalar"
        number(data["result"][1])
      else
        raise Error, "Prometheus returned a #{data["resultType"]}, not a vector or a scalar: make the query return one number"
      end
    end

    def number(text)
      case text
      when "NaN" then Float::NAN
      when "+Inf" then Float::INFINITY
      when "-Inf" then -Float::INFINITY
      else Float(text)
      end
    end
end
