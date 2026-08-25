require "test_helper"

class CommandsServerTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ],
      builder: { "arch" => "amd64" }
    }
  end

  test "ensure run directory migrates the legacy directory before creating it" do
    assert_equal "test -d .kamal && test ! -e .dash && mv .kamal .dash || true && mkdir -p .dash",
      new_command.ensure_run_directory.join(" ")
  end

  test "ensure run directory starts with a shell builtin so SSHKit does not env-prefix the guard" do
    assert_equal :test, new_command.ensure_run_directory.first
  end

  # The auditor runs on the hosts during `build:pull`, before any lock is taken.
  # If it created the run directory with a bare mkdir, `.dash` would already
  # exist by the time the lock's guard ran and the legacy tree would be stranded.
  test "every command that can reach the run directory first emits the same migration" do
    config = Dash::Configuration.new(@config)

    assert_equal Dash::Commands::Server.new(config).ensure_run_directory,
      Dash::Commands::Auditor.new(config).record("noted").first(ENSURE_RUN_DIRECTORY.length)
  end

  test "listeners on port" do
    assert_equal "ss -ltnH sport = :80", new_command.listeners_on(80).join(" ")
  end

  private
    def new_command(extra_config = {})
      Dash::Commands::Server.new(Dash::Configuration.new(@config.merge(extra_config)))
    end
end
