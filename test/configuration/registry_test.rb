require "test_helper"

class ConfigurationRegistryTest < ActiveSupport::TestCase
  test "username and password from literal values" do
    registry = new_registry({ "server" => "ghcr.io", "username" => "dhh", "password" => "secret" })

    assert_equal "dhh", registry.username
    assert_equal "secret", registry.password
  end

  test "username and password from secrets" do
    with_test_secrets("secrets" => "GITHUB_ACTOR=dhh\nGITHUB_TOKEN=token") do
      registry = new_registry({ "server" => "ghcr.io", "username" => [ "GITHUB_ACTOR" ], "password" => [ "GITHUB_TOKEN" ] })

      assert_equal "dhh", registry.username
      assert_equal "token", registry.password
    end
  end

  test "password secret resolving to an empty value raises with the secret name" do
    with_test_secrets("secrets" => "GITHUB_ACTOR=dhh\nGITHUB_TOKEN=") do
      registry = new_registry({ "server" => "ghcr.io", "username" => [ "GITHUB_ACTOR" ], "password" => [ "GITHUB_TOKEN" ] })

      error = assert_raises(Dash::ConfigurationError) { registry.password }
      assert_match /registry\/password: secret 'GITHUB_TOKEN' resolved to an empty value/, error.message
      assert_match /export/, error.message
    end
  end

  test "username secret resolving to an empty value raises with the secret name" do
    with_test_secrets("secrets" => "GITHUB_ACTOR=\nGITHUB_TOKEN=token") do
      registry = new_registry({ "server" => "ghcr.io", "username" => [ "GITHUB_ACTOR" ], "password" => [ "GITHUB_TOKEN" ] })

      error = assert_raises(Dash::ConfigurationError) { registry.username }
      assert_match /registry\/username: secret 'GITHUB_ACTOR' resolved to an empty value/, error.message
    end
  end

  test "blank credentials raise with the accessory context" do
    with_test_secrets("secrets" => "REGISTRY_PASSWORD=") do
      registry = new_registry(
        { "server" => "ghcr.io", "username" => "dhh", "password" => [ "REGISTRY_PASSWORD" ] },
        context: "accessories/db/registry")

      error = assert_raises(Dash::ConfigurationError) { registry.password }
      assert_match /accessories\/db\/registry\/password: secret 'REGISTRY_PASSWORD' resolved to an empty value/, error.message
    end
  end

  test "local registry without credentials does not raise" do
    registry = new_registry({ "server" => "localhost:5000" })

    assert_nil registry.username
    assert_nil registry.password
  end

  test "validate_secrets! surfaces a registry password secret that resolves empty" do
    with_test_secrets("secrets" => "GITHUB_TOKEN=") do
      config = Dash::Configuration.new({
        service: "app", image: "dhh/app",
        registry: { "server" => "ghcr.io", "username" => "dhh", "password" => [ "GITHUB_TOKEN" ] },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ] })

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match /GITHUB_TOKEN/, error.message
    end
  end

  private
    def new_registry(registry_config, context: "registry")
      Dash::Configuration::Registry.new \
        config: { "registry" => registry_config },
        secrets: Dash::Secrets.new(secrets_path: ".dash/secrets"),
        context: context
    end
end
