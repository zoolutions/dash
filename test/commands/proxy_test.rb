require "test_helper"

class CommandsProxyTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ], builder: { "arch" => "amd64" }
    }

    ENV["EXAMPLE_API_KEY"] = "456"
  end

  teardown do
    ENV.delete("EXAMPLE_API_KEY")
  end

  test "run" do
    assert_equal \
      "echo $(cat .kamal/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"):$(cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .kamal/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config",
      new_command.run.join(" ")
  end

  test "run without configuration" do
    @config.delete(:proxy)

    assert_equal \
      "echo $(cat .kamal/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"):$(cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .kamal/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config",
      new_command.run.join(" ")
  end

  test "proxy start" do
    assert_equal \
      "docker container start kamal-proxy",
      new_command.start.join(" ")
  end

  test "proxy stop" do
    assert_equal \
      "docker container stop kamal-proxy",
      new_command.stop.join(" ")
  end

  test "proxy info" do
    assert_equal \
      "docker ps --filter 'name=^kamal-proxy$'",
      new_command.info.join(" ")
  end

  test "proxy logs" do
    assert_equal \
      "docker logs kamal-proxy --timestamps 2>&1",
      new_command.logs.join(" ")
  end

  test "proxy logs since 2h" do
    assert_equal \
      "docker logs kamal-proxy --since 2h --timestamps 2>&1",
      new_command.logs(since: "2h").join(" ")
  end

  test "proxy logs last 10 lines" do
    assert_equal \
      "docker logs kamal-proxy --tail 10 --timestamps 2>&1",
      new_command.logs(lines: 10).join(" ")
  end

  test "proxy logs without timestamps" do
    assert_equal \
      "docker logs kamal-proxy 2>&1",
      new_command.logs(timestamps: false).join(" ")
  end

  test "proxy logs with grep hello!" do
    assert_equal \
      "docker logs kamal-proxy --timestamps 2>&1 | grep 'hello!'",
      new_command.logs(grep: "hello!").join(" ")
  end

  test "proxy remove container" do
    assert_equal \
      "docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_container.join(" ")
  end

  test "proxy remove image" do
    assert_equal \
      "docker image prune --all --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_image.join(" ")
  end

  test "proxy follow logs" do
    assert_equal \
      "ssh -t root@1.1.1.1 -p 22 'docker logs kamal-proxy --timestamps --tail 10 --follow 2>&1'",
      new_command.follow_logs(host: @config[:servers].first)
  end

  test "proxy follow logs with grep hello!" do
    assert_equal \
      "ssh -t root@1.1.1.1 -p 22 'docker logs kamal-proxy --timestamps --tail 10 --follow 2>&1 | grep \"hello!\"'",
      new_command.follow_logs(host: @config[:servers].first, grep: "hello!")
  end

  test "version" do
    assert_equal \
      "docker inspect kamal-proxy --format '{{.Config.Image}}' | awk -F: '{print $NF}'",
      new_command.version.join(" ")
  end

  test "ensure_proxy_directory" do
    assert_equal \
      "mkdir -p .kamal/proxy",
      new_command.ensure_proxy_directory.join(" ")
  end

  test "read_boot_options" do
    assert_equal \
      "cat .kamal/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\"",
      new_command.read_boot_options.join(" ")
  end

  test "read_image" do
    assert_equal \
      "cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"",
      new_command.read_image.join(" ")
  end

  test "read_image_version" do
    assert_equal \
      "cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\"",
      new_command.read_image_version.join(" ")
  end

  test "read_run_command" do
    assert_equal \
      "cat .kamal/proxy/run_command 2> /dev/null || echo \"\"",
      new_command.read_run_command.join(" ")
  end

  test "reset_boot_options" do
    assert_equal \
      "rm .kamal/proxy/options",
      new_command.reset_boot_options.join(" ")
  end

  test "reset_image" do
    assert_equal \
      "rm .kamal/proxy/image",
      new_command.reset_image.join(" ")
  end

  test "reset_image_version" do
    assert_equal \
      "rm .kamal/proxy/image_version",
      new_command.reset_image_version.join(" ")
  end

  test "ensure_apps_config_directory" do
    assert_equal \
      "mkdir -p .kamal/proxy/apps-config",
      new_command.ensure_apps_config_directory.join(" ")
  end

  test "reset_run_command" do
    assert_equal \
      "rm .kamal/proxy/run_command",
      new_command.reset_run_command.join(" ")
  end

  test "registry run config" do
    @config[:proxy] = { "run" => { "registry" => "registry:4443" } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m registry:4443/ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "repository run config" do
    @config[:proxy] = { "run" => { "repository" => "custom/repo" } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m custom/repo:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "image_version run config" do
    @config[:proxy] = { "run" => { "version" => "v1.2.3" } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:v1.2.3 kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "bind_ips run config" do
    @config[:proxy] = { "run" => { "bind_ips" => [ "0.0.0.0", "127.0.0.1" ] } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 0.0.0.0:80:80 --publish 0.0.0.0:443:443 --publish 127.0.0.1:80:80 --publish 127.0.0.1:443:443 --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "log_max_size run config" do
    @config[:proxy] = { "run" => { "log_max_size" => "50m" } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=50m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "domains" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy domains refresh",
      new_command.domains("refresh").join(" ")
  end

  test "debug run config" do
    @config[:proxy] = { "run" => { "debug" => true } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --debug --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "metrics_port run config" do
    @config[:proxy] = { "run" => { "metrics_port" => 9090 } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9090 ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --metrics-port \"9090\" --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "don't publish run config" do
    @config[:proxy] = { "run" => { "publish" => false } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "run with config digest label" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }
    assert_equal \
      "docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --label org.kamal.proxy-config-digest=abc123 --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore",
      new_command.run(digest: "abc123").join(" ")
  end

  test "run with config digest label on legacy boot config path" do
    assert_equal \
      "echo $(cat .kamal/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"):$(cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .kamal/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name kamal-proxy --network kamal --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --label org.kamal.proxy-config-digest=abc123 --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config",
      new_command.run(digest: "abc123").join(" ")
  end

  test "start_or_run passes digest through" do
    @config[:proxy] = { "run" => {} }
    assert_match \
      "--label org.kamal.proxy-config-digest=abc123",
      new_command.start_or_run(digest: "abc123").join(" ")
  end

  test "stop with timeout" do
    assert_equal \
      "docker container stop --time 40 kamal-proxy",
      new_command.stop(timeout: 40).join(" ")
  end

  test "pull" do
    @config[:proxy] = { "run" => { "version" => "v1.2.3" } }
    assert_equal \
      "docker pull ghcr.io/zoolutions/kamal-proxy:v1.2.3",
      new_command.pull.join(" ")
  end

  test "pull on legacy boot config path" do
    assert_equal \
      "docker pull $(cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"):$(cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\")",
      new_command.pull.join(" ")
  end

  test "list" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy list",
      new_command.list.join(" ")
  end

  test "list json" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy list --json",
      new_command.list(json: true).join(" ")
  end

  test "cache stats" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy cache stats",
      new_command.cache_stats.join(" ")
  end

  test "cache stats with count and json" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy cache stats --count --json",
      new_command.cache_stats(count: true, json: true).join(" ")
  end

  test "cache purge" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy cache purge app-web",
      new_command.cache_purge("app-web").join(" ")
  end

  test "cache purge with path prefix" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy cache purge app-web --path-prefix \"/assets\"",
      new_command.cache_purge("app-web", path_prefix: "/assets").join(" ")
  end

  test "mount_destinations" do
    assert_equal \
      "docker inspect kamal-proxy --format '{{range .Mounts}}{{println .Destination}}{{end}}'",
      new_command.mount_destinations.join(" ")
  end

  test "config_digest" do
    assert_equal \
      "docker inspect kamal-proxy --format '{{ index .Config.Labels \"org.kamal.proxy-config-digest\" }}'",
      new_command.config_digest.join(" ")
  end

  test "container_id" do
    assert_equal \
      "docker container ls --all --filter 'name=^kamal-proxy$' --quiet",
      new_command.container_id.join(" ")
  end

  test "run with port_holder joins the holder namespace without publishing" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker run --name kamal-proxy --network container:kamal-proxy-net --detach --restart unless-stopped --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy --volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy run --recheck-targets-on-restore --reuse-port",
      new_command.run.join(" ")
  end

  test "run with a custom container name" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_match \
      "docker run --name kamal-proxy-next --network container:kamal-proxy-net",
      new_command.run(name: "kamal-proxy-next").join(" ")
  end

  test "run_holder" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker run --name kamal-proxy-net --network kamal --detach --restart unless-stopped --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} kamal-proxy hold",
      new_command.run_holder.join(" ")
  end

  test "start_holder_or_run" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_match \
      "docker container start kamal-proxy-net || docker run --name kamal-proxy-net",
      new_command.start_holder_or_run.join(" ")
  end

  test "holder_container_id" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker container ls --filter 'name=^kamal-proxy-net$' --quiet",
      new_command.holder_container_id.join(" ")
  end

  test "disable_restart" do
    assert_equal \
      "docker update --restart=no kamal-proxy",
      new_command.disable_restart.join(" ")
  end

  test "drain" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy drain --drain-timeout=30s",
      new_command.drain(timeout: 30).join(" ")
  end

  test "wait_for_exit" do
    assert_equal \
      "docker wait kamal-proxy",
      new_command.wait_for_exit.join(" ")
  end

  test "remove_stopped_container" do
    assert_equal \
      "docker container rm kamal-proxy-next",
      new_command.remove_stopped_container(name: "kamal-proxy-next").join(" ")
  end

  test "promote_next_container" do
    assert_equal \
      "docker container rename kamal-proxy-next kamal-proxy",
      new_command.promote_next_container.join(" ")
  end

  test "list with a custom container name" do
    assert_equal \
      "docker exec kamal-proxy-next kamal-proxy list",
      new_command.list(name: "kamal-proxy-next").join(" ")
  end

  # Certificate store transfer (kamal proxy export_certs / import_certs). The
  # apps-config bind mount is the one container path that is also a host path,
  # so exported archives travel through it.

  test "export certs through the running proxy" do
    assert_equal \
      "docker exec kamal-proxy kamal-proxy export certs /home/kamal-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs.join(" ")
  end

  test "export certs offline via a one-off container" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_equal \
      "docker run --rm --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy " \
      "--volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config " \
      "ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} " \
      "kamal-proxy export certs /home/kamal-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs_offline.join(" ")
  end

  test "export certs offline falls back to the boot config image without a run config" do
    assert_equal \
      "docker run --rm --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy " \
      "--volume $PWD/.kamal/proxy/apps-config:/home/kamal-proxy/.apps-config " \
      "$(cat .kamal/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/kamal-proxy\"):" \
      "$(cat .kamal/proxy/image_version 2> /dev/null || echo \"#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}\") " \
      "kamal-proxy export certs /home/kamal-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs_offline.join(" ")
  end

  # The source streams through stdin into the one-off container: a bind mount
  # would need host permissions the container user cannot be guaranteed to
  # have, and the store must be written as the image's own user.
  test "import certs from a traefik acme.json" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_equal \
      "docker run --rm --interactive --volume kamal-proxy-config:/home/kamal-proxy/.config/kamal-proxy " \
      "ghcr.io/zoolutions/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} " \
      "sh -c 'cat > /tmp/kamal-cert-import && kamal-proxy import certs --traefik-acme=\"/tmp/kamal-cert-import\"' " \
      "< .kamal/proxy/certs-import",
      new_command.import_certs(traefik_acme: true).join(" ")
  end

  test "import certs with a resolver" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "kamal-proxy import certs --traefik-acme=\"/tmp/kamal-cert-import\" --resolver=\"letsencrypt\"",
      new_command.import_certs(traefik_acme: true, resolver: "letsencrypt").join(" ")
  end

  test "import certs restores an archive with force" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "kamal-proxy import certs --archive=\"/tmp/kamal-cert-import\" --force",
      new_command.import_certs(force: true).join(" ")
  end

  test "import certs verifies an archive" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "kamal-proxy import certs --archive=\"/tmp/kamal-cert-import\" --verify",
      new_command.import_certs(verify: true).join(" ")
  end

  test "cert transfer paths and cleanup" do
    assert_equal ".kamal/proxy/apps-config/certs-export.tar.gz", new_command.certs_archive_host_path
    assert_equal ".kamal/proxy/certs-import", new_command.certs_import_host_path
    assert_equal "rm .kamal/proxy/apps-config/certs-export.tar.gz", new_command.remove_certs_archive.join(" ")
    assert_equal "rm .kamal/proxy/certs-import", new_command.remove_certs_import.join(" ")
  end

  private
    def new_command
      Kamal::Commands::Proxy.new(Kamal::Configuration.new(@config, version: "123"), host: "1.1.1.1")
    end
end
