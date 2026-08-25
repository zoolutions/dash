require_relative "cli_test_case"

class CliRegistryTest < CliTestCase
  test "setup" do
    run_command("setup").tap do |output|
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "setup skip local" do
    run_command("setup", "-L").tap do |output|
      assert_no_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "setup skip remote" do
    run_command("setup", "-R").tap do |output|
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_no_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "remove" do
    run_command("remove").tap do |output|
      assert_match /docker logout as .*@localhost/, output
      assert_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "remove skip local" do
    run_command("remove", "-L").tap do |output|
      assert_no_match /docker logout as .*@localhost/, output
      assert_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "remove skip remote" do
    run_command("remove", "-R").tap do |output|
      assert_match /docker logout as .*@localhost/, output
      assert_no_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "setup with no docker" do
    stub_setup
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with(:docker, "--version", "&&", :docker, :buildx, "version")
      .raises(SSHKit::Command::Failed.new("command not found"))

    assert_raises(Dash::Cli::DependencyError) { run_command("setup") }
  end

  test "allow remote login with no docker" do
    stub_setup
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with(:docker, "--version", "&&", :docker, :buildx, "version")
      .raises(SSHKit::Command::Failed.new("command not found"))

    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with { |*args| args[0..1] == [ :docker, :login ] }

    assert_nothing_raised { run_command("setup", "--skip-local") }
  end

  # The matcher is a plain string, not a regexp: an unescaped `||` inside a
  # regexp literal is an alternation with two empty branches, so it matches
  # everything and the assertion silently stops testing anything.
  test "setup local registry" do
    run_command("setup", fixture: :with_local_registry).tap do |output|
      assert_match "docker start dash-docker-registry || docker run --detach -p 127.0.0.1:5000:5000 --name dash-docker-registry registry:3", output
    end
  end

  test "remove local registry also cleans up a leftover kamal-docker-registry" do
    run_command("remove", fixture: :with_local_registry).tap do |output|
      assert_match "docker stop dash-docker-registry && docker rm dash-docker-registry ; docker stop kamal-docker-registry && docker rm kamal-docker-registry", output
    end
  end

  test "login" do
    run_command("login").tap do |output|
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "login skip local" do
    run_command("login", "-L").tap do |output|
      assert_no_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "login skip remote" do
    run_command("login", "-R").tap do |output|
      assert_match /docker login -u \[REDACTED\] -p \[REDACTED\] as .*@localhost/, output
      assert_no_match /docker login -u \[REDACTED\] -p \[REDACTED\] on 1.1.1.\d/, output
    end
  end

  test "logout" do
    run_command("logout").tap do |output|
      assert_match /docker logout as .*@localhost/, output
      assert_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "logout skip local" do
    run_command("logout", "-L").tap do |output|
      assert_no_match /docker logout as .*@localhost/, output
      assert_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "logout skip remote" do
    run_command("logout", "-R").tap do |output|
      assert_match /docker logout as .*@localhost/, output
      assert_no_match /docker logout on 1.1.1.\d/, output
    end
  end

  test "login with local registry raises error" do
    error = assert_raises(RuntimeError) do
      run_command("login", fixture: :with_local_registry)
    end
    assert_match /Cannot use login command with a local registry. Use `dash registry setup` instead./, error.message
  end

  test "logout with local registry raises error" do
    error = assert_raises(RuntimeError) do
      run_command("logout", fixture: :with_local_registry)
    end
    assert_match /Cannot use logout command with a local registry. Use `dash registry remove` instead./, error.message
  end

  private
    def run_command(*command, fixture: :with_accessories)
      stdouted { Dash::Cli::Registry.start([ *command, "-c", "test/fixtures/deploy_#{fixture}.yml" ]) }
    end
end
