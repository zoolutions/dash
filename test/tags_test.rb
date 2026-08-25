require "test_helper"

class TagsTest < ActiveSupport::TestCase
  test "env emits both the DASH and the legacy KAMAL prefix" do
    env = Dash::Tags.new(version: "abc123", service: "app").env

    assert_equal "abc123", env["DASH_VERSION"]
    assert_equal "abc123", env["KAMAL_VERSION"]
    assert_equal "app", env["DASH_SERVICE"]
    assert_equal "app", env["KAMAL_SERVICE"]
  end

  test "every key is present under both prefixes with the same value" do
    env = Dash::Tags.from_config(Dash::Configuration.new(base_deploy)).env

    dash_env = env.select { |key, _| key.start_with?("DASH_") }
    kamal_env = env.select { |key, _| key.start_with?("KAMAL_") }

    assert dash_env.any?
    assert_equal dash_env.size, kamal_env.size
    assert_equal env.keys.size, dash_env.size + kamal_env.size

    dash_env.each do |key, value|
      assert_equal value, env[key.sub("DASH_", "KAMAL_")]
    end
  end

  test "nil tags are dropped under both prefixes" do
    env = Dash::Tags.new(version: "abc123", destination: nil).env

    assert_not env.key?("DASH_DESTINATION")
    assert_not env.key?("KAMAL_DESTINATION")
  end

  test "except drops a tag from both prefixes" do
    env = Dash::Tags.new(version: "abc123", service: "app").except(:service).env

    assert_not env.key?("DASH_SERVICE")
    assert_not env.key?("KAMAL_SERVICE")
    assert_equal "abc123", env["DASH_VERSION"]
  end

  private
    def base_deploy
      {
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ]
      }
    end
end
