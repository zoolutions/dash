require "test_helper"

class CommandsLoadbalancerTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app",
      image: "dhh/app",
      registry: { "username" => "dhh", "password" => "secret" },
      servers: { "web" => [ "1.1.1.1", "1.1.1.2" ] },
      builder: { "arch" => "amd64" },
      proxy: { "loadbalancer" => "lb.example.com", "hosts" => [ "app.example.com" ] }
    }
  end

  test "run" do
    assert_equal \
      "echo ghcr.io/mhenrixon/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} | xargs docker run --name load-balancer --network kamal --detach --restart unless-stopped --label org.opencontainers.image.title=kamal-loadbalancer #{digest_label} --publish 80:80 --publish 443:443 --volume kamal-loadbalancer-config:/home/kamal-loadbalancer/.config/kamal-loadbalancer",
      new_command.run.join(" ")
  end

  test "run honors proxy.run.publish false and options" do
    @config[:proxy]["run"] = { "publish" => false, "options" => { "label" => [ "traefik.enable=true" ] } }
    assert_equal \
      "echo ghcr.io/mhenrixon/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} | xargs docker run --name load-balancer --network kamal --detach --restart unless-stopped --label org.opencontainers.image.title=kamal-loadbalancer #{digest_label} --log-opt max-size=10m --label \"traefik.enable=true\" --volume kamal-loadbalancer-config:/home/kamal-loadbalancer/.config/kamal-loadbalancer",
      new_command.run.join(" ")
  end

  test "run honors custom publish ports" do
    @config[:proxy]["run"] = { "http_port" => 8080, "https_port" => 8443 }
    assert_equal \
      "echo ghcr.io/mhenrixon/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} | xargs docker run --name load-balancer --network kamal --detach --restart unless-stopped --label org.opencontainers.image.title=kamal-loadbalancer #{digest_label} --publish 8080:80 --publish 8443:443 --log-opt max-size=10m --volume kamal-loadbalancer-config:/home/kamal-loadbalancer/.config/kamal-loadbalancer",
      new_command.run.join(" ")
  end

  test "start" do
    assert_equal \
      "docker container start load-balancer",
      new_command.start.join(" ")
  end

  test "stop" do
    assert_equal \
      "docker container stop load-balancer",
      new_command.stop.join(" ")
  end

  test "start_or_run" do
    assert_equal \
      "docker container start load-balancer || echo ghcr.io/mhenrixon/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} | xargs docker run --name load-balancer --network kamal --detach --restart unless-stopped --label org.opencontainers.image.title=kamal-loadbalancer #{digest_label} --publish 80:80 --publish 443:443 --volume kamal-loadbalancer-config:/home/kamal-loadbalancer/.config/kamal-loadbalancer",
      new_command.start_or_run.join(" ")
  end

  test "deploy with targets" do
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\"",
      new_command.deploy(targets: [ "1.1.1.1", "1.1.1.2" ]).join(" ")
  end

  test "deploy with targets and ssl" do
    @config[:proxy]["ssl"] = true
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\" --tls",
      new_command.deploy(targets: [ "1.1.1.1", "1.1.1.2" ]).join(" ")
  end

  test "deploy with multiple hosts" do
    @config[:proxy]["hosts"] = [ "app1.example.com", "app2.example.com" ]
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app1.example.com\" --host=\"app2.example.com\"",
      new_command.deploy(targets: [ "1.1.1.1" ]).join(" ")
  end

  test "deploy uses app_port for targets" do
    @config[:proxy]["app_port"] = 3000
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:3000,1.1.1.2:3000\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\"",
      new_command.deploy(targets: [ "1.1.1.1", "1.1.1.2" ]).join(" ")
  end

  test "deploy propagates rich proxy options (healthcheck, response timeout, path prefix)" do
    @config[:proxy]["healthcheck"] = { "interval" => 2, "timeout" => 5, "path" => "/healthz" }
    @config[:proxy]["response_timeout"] = 10
    @config[:proxy]["path_prefix"] = "/api"
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --health-check-interval=\"2s\" --health-check-timeout=\"5s\" --health-check-path=\"/healthz\" --target-timeout=\"10s\" --buffer-requests --buffer-responses --path-prefix=\"/api\" --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\"",
      new_command.deploy(targets: [ "1.1.1.1" ]).join(" ")
  end

  # The per-app proxies must NOT also get --basic-auth: kamal-proxy deletes the
  # Authorization header once a service enforces it, so the load balancer would
  # authenticate the client and then forward a credential-less request.
  test "deploy propagates basic auth to the load balancer only" do
    @config[:proxy]["basic_auth"] = { "username" => "admin", "password" => "s3cr3t" }

    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\" --basic-auth=\"admin:s3cr3t\"",
      new_command.deploy(targets: [ "1.1.1.1", "1.1.1.2" ]).join(" ")

    config = Kamal::Configuration.new(@config, version: "123")
    assert_not_includes config.proxy.deploy_options.keys, :"basic-auth"
  end

  test "deploy propagates tls_domains flags" do
    @config[:proxy]["ssl"] = true
    @config[:proxy]["tls_domains"] = { "source" => "/api/v1/kamal/domains", "interval" => 300, "batch_size" => 5 }
    assert_equal \
      "docker exec load-balancer kamal-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\" --host=\"app.example.com\" --tls --tls-domains-source=\"/api/v1/kamal/domains\" --tls-domains-interval=\"300s\" --tls-domains-batch-size=\"5\"",
      new_command.deploy(targets: [ "1.1.1.1", "1.1.1.2" ]).join(" ")
  end

  test "domains" do
    assert_equal \
      "docker exec load-balancer kamal-proxy domains list",
      new_command.domains("list").join(" ")
  end

  test "info" do
    assert_equal \
      "docker ps --filter 'name=^load-balancer$'",
      new_command.info.join(" ")
  end

  test "version" do
    assert_equal \
      "docker inspect load-balancer --format '{{.Config.Image}}' | cut -d: -f2",
      new_command.version.join(" ")
  end

  test "logs" do
    assert_equal \
      "docker logs load-balancer --timestamps 2>&1",
      new_command.logs.join(" ")
  end

  test "logs since 2h" do
    assert_equal \
      "docker logs load-balancer --since 2h --timestamps 2>&1",
      new_command.logs(since: "2h").join(" ")
  end

  test "logs last 10 lines" do
    assert_equal \
      "docker logs load-balancer --tail 10 --timestamps 2>&1",
      new_command.logs(lines: 10).join(" ")
  end

  test "logs without timestamps" do
    assert_equal \
      "docker logs load-balancer 2>&1",
      new_command.logs(timestamps: false).join(" ")
  end

  test "logs with grep" do
    assert_equal \
      "docker logs load-balancer --timestamps 2>&1 | grep 'error'",
      new_command.logs(grep: "error").join(" ")
  end

  test "follow_logs" do
    assert_equal \
      "ssh -t root@lb.example.com -p 22 'docker logs load-balancer --timestamps --tail 10 --follow 2>&1'",
      new_command.follow_logs(host: "lb.example.com")
  end

  test "follow_logs with grep" do
    assert_equal \
      "ssh -t root@lb.example.com -p 22 'docker logs load-balancer --timestamps --tail 10 --follow 2>&1 | grep \"error\"'",
      new_command.follow_logs(host: "lb.example.com", grep: "error")
  end

  test "remove_container" do
    assert_equal \
      "docker container prune --force --filter label=org.opencontainers.image.title=kamal-loadbalancer",
      new_command.remove_container.join(" ")
  end

  # On a shared proxy host the container is created with the kamal-proxy title
  # label, so pruning by the kamal-loadbalancer label would leave it behind and
  # the following `docker run` would collide on the container name.
  test "remove_container on a proxy host prunes by the label it was created with" do
    @config[:proxy]["loadbalancer"] = "1.1.1.1"

    assert_equal \
      "docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_container.join(" ")
  end

  # Image label filters match labels baked into the image, and the load balancer
  # runs the kamal-proxy image - kamal-loadbalancer never matched anything.
  test "remove_image prunes the kamal-proxy image" do
    assert_equal \
      "docker image prune --all --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_image.join(" ")
  end

  test "list" do
    assert_equal \
      "docker exec load-balancer kamal-proxy list",
      new_command.list.join(" ")
  end

  test "config_digest" do
    assert_equal \
      "docker inspect load-balancer --format '{{ index .Config.Labels \"org.kamal.proxy-config-digest\" }}'",
      new_command.config_digest.join(" ")
  end

  test "run labels the container with the config digest" do
    digest = new_loadbalancer_config.run_config_digest

    assert_match "--label org.kamal.proxy-config-digest=#{digest}", new_command.run.join(" ")
  end

  test "run config digest changes when proxy.run changes" do
    default_digest = new_loadbalancer_config.run_config_digest
    @config[:proxy]["run"] = { "http_port" => 8080 }

    assert_not_equal default_digest, new_loadbalancer_config.run_config_digest
  end

  test "ensure_services_directory" do
    assert_equal \
      "mkdir -p .kamal/loadbalancer/services",
      new_command.ensure_services_directory.join(" ")
  end

  test "read_service_owner" do
    assert_equal \
      "cat .kamal/loadbalancer/services/app 2> /dev/null || echo \"\"",
      new_command.read_service_owner.join(" ")
  end

  test "read_run_config_record" do
    assert_equal \
      "cat .kamal/loadbalancer/run_config 2> /dev/null || echo \"\"",
      new_command.read_run_config_record.join(" ")
  end

  # Two apps are only the same owner when both the repository and the
  # destination-qualified service name match - the load balancer registers
  # services under the bare service name, so destinations collide too.
  test "owner_token distinguishes apps and destinations" do
    base = new_loadbalancer_config.owner_token

    assert_not_equal base, new_loadbalancer_config(destination: "staging").owner_token

    @config[:image] = "dhh/other"
    assert_not_equal base, new_loadbalancer_config.owner_token
  end

  test "run_config_record pairs the owner with the digest" do
    lb = new_loadbalancer_config

    assert_equal "#{lb.owner_token} #{lb.run_config_digest}", lb.run_config_record
  end

  test "ensure_directory" do
    assert_equal \
      "mkdir -p .kamal/loadbalancer",
      new_command.ensure_directory.join(" ")
  end

  test "remove_directory" do
    assert_equal \
      "rm -r .kamal/loadbalancer",
      new_command.remove_directory.join(" ")
  end

  private
    def new_command
      Kamal::Commands::Loadbalancer.new(new_config, loadbalancer_config: new_loadbalancer_config)
    end

    def new_config(destination: nil)
      Kamal::Configuration.new(@config, destination: destination, version: "123")
    end

    def digest_label
      "--label #{Kamal::Commands::Proxy::CONFIG_DIGEST_LABEL}=#{new_loadbalancer_config.run_config_digest}"
    end

    def new_loadbalancer_config(destination: nil)
      config = new_config(destination: destination)
      Kamal::Configuration::Loadbalancer.new(
        config: config,
        proxy_config: config.proxy.proxy_config,
        secrets: config.secrets
      )
    end
end
