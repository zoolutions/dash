require_relative "mcp_test_case"
require "net/http"

class McpRedactionTest < McpTestCase
  SECRETS = { "MYSQL_ROOT_PASSWORD" => "mysql-root-secret", "KAMAL_REGISTRY_PASSWORD" => "registry-secret-pw" }

  # config.to_h carries neither the registry password nor env.secret values, so a config
  # call alone would pass vacuously. Push a payload that does carry them through a tool.
  test "a secret value is blanked wherever a tool returns it" do
    Dash::Diagnostics::Config.any_instance.stubs(:snapshot).returns(
      registry: { username: "user", password: "registry-secret-pw" },
      env: { clear: { "DATABASE_URL" => "mysql://root:mysql-root-secret@db/app" }, secret: [ "MYSQL_ROOT_PASSWORD" ] },
      note: "logged in with registry-secret-pw")

    text, _ = call_tool("config", {}, on: server(session(secrets: SECRETS)))

    assert_no_match "registry-secret-pw", text
    assert_no_match "mysql-root-secret", text
    config = JSON.parse(text)
    assert_equal "[REDACTED]", config.dig("registry", "password")
    assert_equal "mysql://root:[REDACTED]@db/app", config.dig("env", "clear", "DATABASE_URL")
    assert_equal "logged in with [REDACTED]", config["note"]
  end

  test "the config tool redacts ssh key material and the accessories' secret env" do
    config = call_json("config", {}, on: server(session(fixture: :deploy_with_accessories, secrets: SECRETS)))
    assert_equal "[REDACTED]", config.dig("config", "accessories", "mysql", "env", "secret")

    config = call_json("config", {}, on: server(session(fixture: :deploy_with_ssh_keys)))
    assert_equal "[REDACTED]", config.dig("config", "ssh_options", "keys")
    assert_equal "[REDACTED]", config.dig("config", "ssh_options", "key_data")
    assert_equal "root", config.dig("config", "ssh_options", "user")
  end

  test "pool_members never carries the UpCloud credentials" do
    credentials = { "UPCLOUD_USERNAME" => "upcloud-api-user", "UPCLOUD_PASSWORD" => "upcloud-api-secret" }
    credentials.each { |key, value| Dash::Secrets.any_instance.stubs(:[]).with(key).returns(value) }
    sent = []
    unauthorized = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized").tap { |response| response.stubs(:body).returns("{}") }
    http = stub("http")
    http.stubs(:request).with { |request| sent << request["Authorization"] }.returns(unauthorized)
    Net::HTTP.stubs(:start).yields(http)

    text, _ = call_tool("pool_members", {}, on: server(session(fixture: :deploy_with_scale, secrets: credentials)))

    assert_no_match "upcloud-api-secret", text
    assert_no_match "upcloud-api-user", text
    assert_no_match [ "upcloud-api-user:upcloud-api-secret" ].pack("m0"), text
    assert_match "answered 401", text
    assert_equal [ "Basic #{[ "upcloud-api-user:upcloud-api-secret" ].pack("m0")}" ], sent, "the credentials went to the API as basic auth"
  end

  test "an error message is redacted too" do
    Dash::Diagnostics::Containers.any_instance.stubs(:snapshot).raises(SSHKit::Command::Failed, "docker login -p registry-secret-pw failed")

    text, error = call_tool("containers", {}, on: server(session(secrets: SECRETS)))

    assert error
    assert_equal "SSHKit::Command::Failed: docker login -p [REDACTED] failed", text
  end
end
