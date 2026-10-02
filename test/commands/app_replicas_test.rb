require "test_helper"

class CommandsAppReplicasTest < ActiveSupport::TestCase
  setup do
    setup_test_secrets("secrets" => "RAILS_MASTER_KEY=456")

    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      servers: {
        "web" => { "hosts" => [ "1.1.1.1" ], "replicas" => 2 },
        "payments" => { "hosts" => [ "1.1.1.2" ], "healthcheck" => false, "replicas" => { "min" => 1, "max" => 3 } },
        "payments-batch" => { "hosts" => [ "1.1.1.2" ], "healthcheck" => false },
        "workers" => { "hosts" => [ "1.1.1.2" ], "healthcheck" => false }
      }
    }
  end

  teardown do
    teardown_test_secrets
  end

  test "run names a slot and labels every replica of a scalable role" do
    run = new_command(replica: 2).run.join(" ")

    assert_match "--name app-web.2-999 ", run
    assert_match "--env KAMAL_CONTAINER_NAME=\"app-web.2-999\"", run
    assert_match "--env DASH_REPLICA=\"2\"", run
    assert_match "--label replica=\"2\"", run
  end

  test "run keeps slot 1's name and labels it when the role is scalable" do
    run = new_command.run.join(" ")

    assert_match "--name app-web-999 ", run
    assert_match "--env DASH_REPLICA=\"1\"", run
    assert_match "--label replica=\"1\"", run
  end

  test "a role without replicas runs exactly as before" do
    run = new_command(role: "workers", host: "1.1.1.2").run.join(" ")

    assert_no_match(/replica/i, run)
  end

  test "lookups of a slot filter on the slot's name prefix as well as the role labels" do
    assert_equal \
      "sh -c 'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter '\\''name=^app-web\\.2-'\\'' --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter '\\''name=^app-web\\.2-'\\'' --filter status=running --filter status=restarting' | head -1 | while read line; do echo ${line#app-web.2-}; done",
      new_command(replica: 2).current_running_version.join(" ")
  end

  test "slot 1 of a scalable role is filtered too, so it never reads another slot's container" do
    assert_match "--filter '\\''name=^app-web-'\\''", new_command.current_running_version.join(" ")
    assert_match "--filter 'name=^app-web-' --filter status=running", new_command.list_versions(statuses: [ :running ]).join(" ")
  end

  test "a role whose name extends another is still excluded by the role label" do
    payments = new_command(role: "payments", host: "1.1.1.2").list_versions.join(" ")

    assert_match "--filter label=role=payments --filter 'name=^app-payments-'", payments
  end

  test "regex metacharacters in the destination are escaped" do
    @destination = "eu.west"

    assert_match "'name=^app-web\\.2-eu\\.west-'", new_command(replica: 2).list_versions.join(" ")
  end

  test "container_id_for_version targets the slot's container" do
    assert_equal \
      "docker container ls --all --filter 'name=^app-web.2-123$' --quiet",
      new_command(replica: 2).container_id_for_version("123").join(" ")
  end

  test "stop with version stops the slot's container" do
    assert_equal \
      "docker container ls --all --filter 'name=^app-web.2-123$' --quiet | xargs docker stop",
      new_command(replica: 2).stop(version: "123").join(" ")
  end

  test "signal sends a signal to the slot's container" do
    assert_equal \
      "docker container ls --all --filter 'name=^app-payments.3-123$' --quiet | xargs docker kill --signal=TSTP",
      new_command(role: "payments", host: "1.1.1.2", replica: 3).signal("TSTP", version: "123").join(" ")
  end

  test "info and remove_containers cover every slot of the role" do
    assert_equal "docker ps --filter label=service=app --filter label=destination= --filter label=role=web", new_command.info.join(" ")
    assert_equal "docker container prune --force --filter label=service=app --filter label=destination= --filter label=role=web", new_command.remove_containers.join(" ")
  end

  test "active_containers lists every slot's running container" do
    assert_equal \
      "docker ps --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --format \"{{.Names}}\"",
      new_command.active_containers.join(" ")
  end

  test "boot_states asks about every slot up to max in one command" do
    states = new_command(role: "payments", host: "1.1.1.2").boot_states("999").join(" ")

    assert_equal 4, states.scan(Dash::Commands::App::BOOT_STATE_SEPARATOR).size, states
    assert states.start_with?(new_command(role: "payments", host: "1.1.1.2").boot_state("999").join(" ")), states
    assert_match "echo --%-- ; docker ps --filter label=service=app --filter label=destination= --filter label=role=payments --filter status=running --filter status=restarting --format \"{{.Names}}\"", states
    assert_match "docker container ls --all --filter 'name=^app-payments.2-999$' --quiet", states
    assert_match "docker container ls --all --filter 'name=^app-payments.3-999$' --quiet", states
  end

  test "boot_states for a role without replicas still reads the active containers" do
    workers = new_command(role: "workers", host: "1.1.1.2")

    assert_equal \
      "#{workers.boot_state("999").join(" ")} ; echo --%-- ; docker ps --filter label=service=app --filter label=destination= --filter label=role=workers --filter status=running --filter status=restarting --format \"{{.Names}}\"",
      workers.boot_states("999").join(" ")
  end

  test "split_states returns every segment" do
    output = "abc\n--%--\n999\n--%--\napp-web-999\napp-web.2-999\n--%--\n\n"

    assert_equal [ "abc", "999", "app-web-999\napp-web.2-999", "" ], Dash::Commands::App.split_states(output).map(&:strip)
  end

  private
    def new_command(role: "web", host: "1.1.1.1", replica: 1)
      config = Dash::Configuration.new(@config, destination: @destination, version: "999")
      Dash::Commands::App.new(config, role: config.role(role), host: host, replica: replica)
    end
end
