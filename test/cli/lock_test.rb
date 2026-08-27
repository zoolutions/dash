require_relative "cli_test_case"

class CliLockTest < CliTestCase
  test "status" do
    run_command("status").tap do |output|
      assert_match "Running /usr/bin/env stat .dash/lock-app > /dev/null && cat .dash/lock-app/details | base64 -d on 1.1.1.1", output
    end
  end

  test "release" do
    run_command("release").tap do |output|
      assert_match "Released the deploy lock", output
    end
  end

  test "status when there is no deploy lock" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_debug)
      .raises(RuntimeError, "cat: .dash/lock-app/details: No such file or directory")

    run_command("status").tap do |output|
      assert_match "There is no deploy lock", output
    end
  end

  test "release when there is no deploy lock" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(RuntimeError, "rm: cannot remove '.dash/lock-app/details': No such file or directory")

    run_command("release").tap do |output|
      assert_match "There is no deploy lock", output
    end
  end

  test "status --server reports every server-lock host" do
    run_command("status", "--server").tap do |output|
      assert_match "Server lock on 1.1.1.1:", output
      assert_match "Running /usr/bin/env stat .dash/lock-server > /dev/null && cat .dash/lock-server/details | base64 -d on 1.1.1.1", output
      assert_match "Server lock on 1.1.1.2:", output
      assert_match "Running /usr/bin/env stat .dash/lock-server > /dev/null && cat .dash/lock-server/details | base64 -d on 1.1.1.2", output
    end
  end

  test "status --server when there is no server lock" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_debug)
      .raises(RuntimeError, "cat: .dash/lock-server/details: No such file or directory")

    run_command("status", "--server").tap do |output|
      assert_match "There is no server lock on 1.1.1.1", output
      assert_match "There is no server lock on 1.1.1.2", output
    end
  end

  test "release --server clears the lock on every server-lock host" do
    run_command("release", "--server").tap do |output|
      assert_match "Running /usr/bin/env rm .dash/lock-server/details && rm -r .dash/lock-server on 1.1.1.1", output
      assert_match "Running /usr/bin/env rm .dash/lock-server/details && rm -r .dash/lock-server on 1.1.1.2", output
      assert_match "Released the server lock", output
    end
  end

  test "release --server when there is no server lock" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(RuntimeError, "rm: cannot remove '.dash/lock-server/details': No such file or directory")

    run_command("release", "--server").tap do |output|
      assert_match "Released the server lock", output
    end
  end

  private
    def run_command(*command)
      stdouted { Dash::Cli::Lock.start([ *command, "-v", "-c", "test/fixtures/deploy_with_accessories.yml" ]) }
    end
end
