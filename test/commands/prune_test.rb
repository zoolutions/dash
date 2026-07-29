require "test_helper"

class CommandsPruneTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ],
      builder: { "arch" => "amd64" }
    }
  end

  test "dangling images" do
    assert_equal \
      "docker image prune --force --filter label=service=app",
      new_command.dangling_images.join(" ")
  end

  test "tagged images" do
    assert_equal \
      "docker image ls --filter label=service=app --format '{{.ID}} {{.Repository}}:{{.Tag}}' | grep -v -w \"$(docker container ls -a --format '{{.Image}}\\|' --filter label=service=app | tr -d '\\n')dhh/app:latest\\|dhh/app:<none>\" | while read image tag; do docker rmi $tag; done",
      new_command.tagged_images.join(" ")
  end

  test "app containers" do
    assert_equal \
      "docker ps -q -a --filter label=service=app --filter label=destination= --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n +6 | while read container_id; do docker rm $container_id; done",
      new_command.app_containers(retain: 5, role: role(:web)).join(" ")

    assert_equal \
      "docker ps -q -a --filter label=service=app --filter label=destination= --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n +4 | while read container_id; do docker rm $container_id; done",
      new_command.app_containers(retain: 3, role: role(:web)).join(" ")
  end

  test "app containers are scoped to the role, so a sibling role's deploys can't push a slept container past the retain window" do
    @config[:servers] = { "web" => [ "1.1.1.1" ], "workers" => [ "1.1.1.2" ] }

    assert_match "--filter label=role=workers", new_command.app_containers(retain: 5, role: role(:workers)).join(" ")
    assert_no_match(/--filter label=role=web /, new_command.app_containers(retain: 5, role: role(:workers)).join(" "))
  end

  test "app containers are scoped to the destination" do
    assert_equal \
      "docker ps -q -a --filter label=service=app --filter label=destination=staging --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n +6 | while read container_id; do docker rm $container_id; done",
      new_command(destination: "staging").app_containers(retain: 5, role: role(:web, destination: "staging")).join(" ")
  end

  private
    def new_command(destination: nil)
      Kamal::Commands::Prune.new(config(destination: destination))
    end

    def config(destination: nil)
      Kamal::Configuration.new(@config, version: "123", destination: destination)
    end

    def role(name, destination: nil)
      config(destination: destination).role(name)
    end
end
