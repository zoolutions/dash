require "test_helper"

class CommandsLockTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ],
      builder: { "arch" => "amd64" }
    }
  end

  test "status" do
    assert_equal \
      "stat .kamal/lock-app-production > /dev/null && cat .kamal/lock-app-production/details | base64 -d",
      new_command.status.join(" ")
  end

  test "acquire" do
    assert_match \
      %r{mkdir \.kamal/lock-app-production && echo ".*" > \.kamal/lock-app-production/details}m,
      new_command.acquire("Hello", "123").join(" ")
  end

  test "acquire encodes non-ASCII lock details for shell" do
    Dash::Git.stubs(:user_name).returns("Сергей Федоров")

    command = new_command.acquire("Hello", "123").join(" ")
    encoded_details = command.match(/echo "(.*)" > \.kamal\/lock-app-production\/details/m)[1]

    assert_predicate command, :ascii_only?
    assert_includes Base64.decode64(encoded_details).force_encoding(Encoding::UTF_8), "Locked by: Сергей Федоров"
  end

  test "release" do
    assert_match \
      "rm .kamal/lock-app-production/details && rm -r .kamal/lock-app-production",
      new_command.release.join(" ")
  end

  test "server-scoped lock omits service and destination so every deploy collides" do
    assert_equal \
      "stat .kamal/lock-server > /dev/null && cat .kamal/lock-server/details | base64 -d",
      new_command(scope: :server).status.join(" ")
  end

  test "server-scoped acquire and release target the shared directory" do
    assert_match \
      %r{mkdir \.kamal/lock-server && echo ".*" > \.kamal/lock-server/details}m,
      new_command(scope: :server).acquire("Hello", "123").join(" ")

    assert_match \
      "rm .kamal/lock-server/details && rm -r .kamal/lock-server",
      new_command(scope: :server).release.join(" ")
  end

  test "a second destination shares the server lock but not the deploy lock" do
    other = Dash::Configuration.new(@config, version: "123", destination: "staging")

    assert_equal \
      Dash::Commands::Lock.new(other, scope: :server).acquire("Hi", "1").first(2),
      new_command(scope: :server).acquire("Hi", "1").first(2)

    refute_equal \
      Dash::Commands::Lock.new(other).acquire("Hi", "1").first(2),
      new_command.acquire("Hi", "1").first(2)
  end

  test "unknown scope is rejected" do
    assert_raises(ArgumentError) { new_command(scope: :galaxy) }
  end

  private
    def new_command(scope: :destination)
      Dash::Commands::Lock.new(
        Dash::Configuration.new(@config, version: "123", destination: "production"), scope: scope)
    end
end
