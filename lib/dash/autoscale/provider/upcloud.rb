require "net/http"
require "json"
require "securerandom"
require "uri"

# UpCloud API 1.3 (https://developers.upcloud.com/1.3/8-servers/) over Net::HTTP. The
# credentials are lambdas so the secrets are read on the first request, never earlier, and
# they only ever travel as basic auth - error messages carry the path and the status.
class Dash::Autoscale::Provider::Upcloud < Dash::Autoscale::Provider::Base
  API = URI("https://api.upcloud.com")
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 60

  NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError ]

  def initialize(username:, password:)
    @username = username
    @password = password
  end

  # The list is filtered by label on the server and again here: a member is only ever a
  # server that carries every one of the role's labels. The list has no addresses, so each
  # match is read once more for them.
  def members(labels:, address:)
    query = URI.encode_www_form(labels.map { |key, value| [ "label", "#{key}=#{value}" ] })
    servers = request(:get, "/1.3/server?#{query}").dig("servers", "server") || []

    servers.select { |server| labelled?(server, labels) }.map do |server|
      member_from(request(:get, "/1.3/server/#{server["uuid"]}").fetch("server"), labels: labels, address: address)
    end
  end

  def start(member)
    request(:post, "/1.3/server/#{member.id}/start", {})
  end

  def stop(member, timeout:)
    request(:post, "/1.3/server/#{member.id}/stop", { stop_server: { stop_type: "soft", timeout: timeout.to_s } })
  end

  def create(labels:, template:, address:)
    server = request(:post, "/1.3/server", { server: create_body(labels: labels, template: template) }).fetch("server")
    member_from(server, labels: labels, address: address)
  end

  def destroy(member)
    request(:delete, "/1.3/server/#{member.id}?storages=1")
  end

  def state(member)
    request(:get, "/1.3/server/#{member.id}").dig("server", "state")
  end

  private
    def labelled?(server, labels)
      present = Array(server.dig("labels", "label")).to_h { |label| [ label["key"], label["value"] ] }
      labels.all? { |key, value| present[key] == value }
    end

    def member_from(server, labels:, address:)
      Dash::Autoscale::Member.new \
        id: server["uuid"],
        host: address_of(server, address) || raise(Dash::Autoscale::ProviderError, "upcloud: server #{server["uuid"]} has no #{address} address, set scale/address to one it has"),
        role: labels["dash.role"],
        state: server["state"],
        labels: labels,
        created_at: server["created"]
    end

    # IPv4 first: an IPv6 host would need brackets everywhere dash builds `host:port`.
    def address_of(server, access)
      addresses = Array(server.dig("ip_addresses", "ip_address")).select { |ip| ip["access"] == access }
      (addresses.find { |ip| ip["family"] == "IPv4" } || addresses.first)&.fetch("address")
    end

    # Public and utility interfaces always, so a member can pull its image and reach the
    # zone's private services; the SDN interface when the template names one.
    def create_body(labels:, template:)
      name = [ labels["dash.service"], labels["dash.role"], SecureRandom.hex(4) ].join("-")

      {
        zone: template["zone"],
        title: name,
        hostname: name,
        plan: template["plan"],
        metadata: "yes",
        labels: { label: labels.map { |key, value| { key: key, value: value } } },
        storage_devices: { storage_device: [ { action: "clone", storage: template["storage"], title: "#{name}-disk" } ] },
        networking: { interfaces: { interface: interfaces(template["network"]) } },
        login_user: login_user(template),
        user_data: template["user_data"]
      }.compact
    end

    def interfaces(network)
      ipv4 = { ip_address: [ { family: "IPv4" } ] }

      [ { index: 1, type: "public", ip_addresses: ipv4 }, { index: 2, type: "utility", ip_addresses: ipv4 } ].tap do |interfaces|
        interfaces << { index: 3, type: "private", network: network, ip_addresses: ipv4 } if network.present?
      end
    end

    def login_user(template)
      if template["login_user"].present?
        { username: template["login_user"], create_password: "no", ssh_keys: { ssh_key: Array(template["ssh_keys"]) } }
      end
    end

    def request(method, path, body = nil)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(path, "Accept" => "application/json")
      request.basic_auth(@username.call, @password.call)

      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      response = nil
      Net::HTTP.start(API.host, API.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| response = http.request(request) }
      parse(method, path, response)
    rescue *NETWORK_ERRORS => e
      raise Dash::Autoscale::ProviderError, "upcloud: #{method.upcase} #{path.split("?").first} failed (#{e.class}: #{e.message})"
    end

    def parse(method, path, response)
      unless response.is_a?(Net::HTTPSuccess)
        raise Dash::Autoscale::ProviderError, "upcloud: #{method.upcase} #{path.split("?").first} answered #{response.code} #{api_error(response)}".strip
      end

      response.body.present? ? JSON.parse(response.body) : {}
    rescue JSON::ParserError
      raise Dash::Autoscale::ProviderError, "upcloud: #{method.upcase} #{path.split("?").first} answered something that is not JSON"
    end

    def api_error(response)
      error = JSON.parse(response.body.to_s).fetch("error", {})
      [ error["error_code"], error["error_message"] ].compact.join(": ")
    rescue JSON::ParserError
      response.message
    end
end
