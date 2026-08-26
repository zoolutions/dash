require "test_helper"

class CommandsDockerTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ], builder: { "arch" => "amd64" }
    }
    @docker = Dash::Commands::Docker.new(Dash::Configuration.new(@config))
  end

  test "install" do
    assert_equal "sh -c 'curl -fsSL https://get.docker.com || wget -O - https://get.docker.com || echo \"exit 1\"' | sh", @docker.install.join(" ")
  end

  test "installed?" do
    assert_equal "docker -v", @docker.installed?.join(" ")
  end

  test "running?" do
    assert_equal "docker version", @docker.running?.join(" ")
  end

  test "superuser?" do
    assert_equal '[ "${EUID:-$(id -u)}" -eq 0 ] || sudo -nl usermod >/dev/null', @docker.superuser?.join(" ")
  end

  test "root?" do
    assert_equal '[ "${EUID:-$(id -u)}" -eq 0 ]', @docker.root?.join(" ")
  end

  test "in_docker_group?" do
    assert_equal 'id -nG "${USER:-$(id -un)}" | grep -qw docker', @docker.in_docker_group?.join(" ")
  end

  test "add_to_docker_group" do
    assert_equal 'sudo -n usermod -aG docker "${USER:-$(id -un)}"', @docker.add_to_docker_group.join(" ")
  end

  test "refresh_session" do
    assert_equal "kill -HUP $PPID", @docker.refresh_session.join(" ")
  end

  test "manifest_available?" do
    assert_equal "docker manifest inspect basecamp/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}",
      @docker.manifest_available?("basecamp/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}").join(" ")
  end

  test "create_network uses the current network name" do
    assert_equal "docker network create dash", @docker.create_network.join(" ")
  end

  # Stage 3c: docker cannot rename a network, so `dash` is created alongside
  # `kamal` and everything still on the old one is joined to the new one. App
  # containers are replaced by the next deploy anyway; accessories are not,
  # which is the whole point - without this a renamed proxy cannot reach `db`.
  test "connect_legacy_network_containers bridges the old network into the new one" do
    command = @docker.connect_legacy_network_containers.join(" ")

    assert_match "docker network inspect kamal > /dev/null 2>&1 &&", command
    assert_match "docker network connect dash {}", command
  end

  # A host that never had the legacy network must not fail its deploy, and a
  # container already on both networks makes `network connect` fail - so each
  # connect swallows its own failure and the sweep as a whole exits zero.
  test "connect_legacy_network_containers cannot fail a deploy" do
    command = @docker.connect_legacy_network_containers.join(" ")

    assert_match "|| true'", command, "a container already attached must not abort the sweep"
    assert command.end_with?("|| true"), "a host with no legacy network must still exit zero"
  end
end
