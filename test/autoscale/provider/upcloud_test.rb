require "test_helper"
require "net/http"

class AutoscaleProviderUpcloudTest < ActiveSupport::TestCase
  LABELS = { "dash.service" => "app", "dash.destination" => "-", "dash.role" => "payments" }

  setup do
    @requests = []
    @http = stub("http")
    Net::HTTP.stubs(:start).with("api.upcloud.com", 443, has_entries(use_ssl: true)).yields(@http)
    @provider = Dash::Autoscale::Provider::Upcloud.new(username: -> { "api-user" }, password: -> { "api-secret" })
  end

  test "members lists by label, keeps only fully labelled servers and reads each for its address" do
    respond list(server("u1", LABELS), server("u2", LABELS.merge("dash.role" => "web"))),
      details("u1", "started", [ ip("private", "10.0.0.22"), ip("public", "94.1.1.1"), ip("private", "fd00::1", "IPv6") ])

    members = @provider.members(labels: LABELS, address: "private")

    assert_equal 1, members.size
    assert_equal [ "u1", "10.0.0.22", "payments", "started" ], members.first.to_h.values_at(:id, :host, :role, :state)
    assert_equal "/1.3/server?label=dash.service%3Dapp&label=dash.destination%3D-&label=dash.role%3Dpayments", @requests.first.path
    assert_equal "/1.3/server/u1", @requests[1].path
  end

  test "members picks the address the role asks for" do
    respond list(server("u1", LABELS)), details("u1", "stopped", [ ip("private", "10.0.0.22"), ip("public", "94.1.1.1") ])

    assert_equal "94.1.1.1", @provider.members(labels: LABELS, address: "public").first.host
  end

  test "a member without an address of the role's access is an error, not a nil host" do
    respond list(server("u1", LABELS)), details("u1", "started", [ ip("public", "94.1.1.1") ])

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_equal "upcloud: server u1 has no private IPv4 address, set scale/address to one it has", error.message
  end

  test "an IPv6-only member is an error, never an unbracketed host" do
    respond list(server("u1", LABELS)), details("u1", "started", [ ip("private", "fd00::1", "IPv6") ])

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_equal "upcloud: server u1 has no private IPv4 address, set scale/address to one it has", error.message
  end

  test "requests authenticate with basic auth and never put credentials in the path" do
    respond list

    @provider.members(labels: LABELS, address: "private")

    assert_equal "Basic #{[ "api-user:api-secret" ].pack("m0")}", @requests.first["Authorization"]
    assert_no_match(/api-secret/, @requests.first.path)
  end

  test "start, stop and destroy" do
    member = Dash::Autoscale::Member.new(id: "u1", host: "10.0.0.22", role: "payments", state: "stopped")
    respond({}, {}, nil)

    @provider.start(member)
    @provider.stop(member, timeout: 40)
    @provider.destroy(member)

    assert_equal [ [ "POST", "/1.3/server/u1/start" ], [ "POST", "/1.3/server/u1/stop" ], [ "DELETE", "/1.3/server/u1?storages=1" ] ],
      @requests.map { |request| [ request.method, request.path ] }
    assert_equal({ "stop_server" => { "stop_type" => "soft", "timeout" => "40" } }, JSON.parse(@requests[1].body))
  end

  test "create clones the template storage, labels the server and attaches the network" do
    template = { "storage" => "tmpl", "plan" => "CLOUDNATIVE-2xCPU-4GB", "zone" => "de-fra1", "login_user" => "deploy",
                 "ssh_keys" => [ "ssh-ed25519 AAAA" ], "network" => "net-1", "user_data" => "#!/bin/sh\n" }
    respond({ "server" => { "uuid" => "u9", "state" => "maintenance", "ip_addresses" => { "ip_address" => [ ip("private", "10.0.0.30") ] } } })

    member = @provider.create(labels: LABELS, template: template, address: "private")
    body = JSON.parse(@requests.first.body).fetch("server")

    assert_equal [ "u9", "10.0.0.30", "maintenance" ], [ member.id, member.host, member.state ]
    assert_equal "/1.3/server", @requests.first.path
    assert_equal [ "de-fra1", "CLOUDNATIVE-2xCPU-4GB", "yes", "#!/bin/sh\n" ], body.values_at("zone", "plan", "metadata", "user_data")
    assert_equal({ "action" => "clone", "storage" => "tmpl" }, body.dig("storage_devices", "storage_device", 0).except("title"))
    assert_equal LABELS, body.dig("labels", "label").to_h { |label| [ label["key"], label["value"] ] }
    assert_equal [ "ssh-ed25519 AAAA" ], body.dig("login_user", "ssh_keys", "ssh_key")
    assert_equal [ "public", "utility", "private" ], body.dig("networking", "interfaces", "interface").map { |interface| interface["type"] }
    assert_equal "net-1", body.dig("networking", "interfaces", "interface", 2, "network")
  end

  test "an API error names the path and the UpCloud error, not the credentials" do
    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    response.stubs(:body).returns({ error: { error_code: "AUTHENTICATION_FAILED", error_message: "Authentication failed using the given username and password." } }.to_json)
    respond response

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_equal "upcloud: GET /1.3/server answered 401 AUTHENTICATION_FAILED: Authentication failed using the given username and password.", error.message
    assert_no_match(/api-secret|api-user/, error.message)
  end

  test "a network failure becomes a provider error" do
    Net::HTTP.stubs(:start).raises(SocketError, "getaddrinfo: nodename nor servname provided")

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_match %r{upcloud: GET /1.3/server failed \(SocketError}, error.message
  end

  test "state reads the server" do
    respond details("u1", "stopped", [])

    assert_equal "stopped", @provider.state(Dash::Autoscale::Member.new(id: "u1"))
  end

  test "wait_until polls until the state is reached" do
    member = Dash::Autoscale::Member.new(id: "u1")
    @provider.stubs(:state).returns("maintenance", "maintenance", "started")
    @provider.expects(:sleep).with(0).twice

    assert_equal "started", @provider.wait_until(member, state: "started", timeout: 30, interval: 0)
  end

  test "wait_until gives up after the timeout" do
    member = Dash::Autoscale::Member.new(id: "u1")
    @provider.stubs(:state).returns("maintenance")

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.wait_until(member, state: "started", timeout: 0, interval: 0) }
    assert_equal "upcloud: u1 is maintenance, not started, after 0s", error.message
  end

  private
    def respond(*bodies)
      responses = bodies.map do |body|
        next body if body.is_a?(Net::HTTPResponse)

        Net::HTTPOK.new("1.1", "200", "OK").tap { |response| response.stubs(:body).returns(body.nil? ? "" : body.to_json) }
      end

      @http.unstub(:request)
      @http.stubs(:request).with do |request|
        @requests << request
        true
      end.returns(*responses)
    end

    def list(*servers)
      { "servers" => { "server" => servers } }
    end

    def server(uuid, labels)
      { "uuid" => uuid, "state" => "started", "labels" => { "label" => labels.map { |key, value| { "key" => key, "value" => value } } } }
    end

    def details(uuid, state, addresses)
      { "server" => { "uuid" => uuid, "state" => state, "ip_addresses" => { "ip_address" => addresses } } }
    end

    def ip(access, address, family = "IPv4")
      { "access" => access, "address" => address, "family" => family }
    end
end
