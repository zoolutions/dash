require_relative "cli_test_case"

class CliDoctorTest < CliTestCase
  PROXY_VERSION_CAPTURE_ARGS = [ :docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'" ]
  LEGACY_PROXY_VERSION_CAPTURE_ARGS = [ :docker, :inspect, "kamal-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'" ]

  setup do
    Thread.report_on_exception = false
    # The Printer backend never sets an exit status, so execute would report
    # every check as failed. Default to success; individual tests override.
    SSHKit::Backend::Abstract.any_instance.stubs(:execute).returns(true)
  end

  teardown do
    Thread.report_on_exception = false
  end

  test "doctor with everything healthy" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: connected", output
      assert_match "OK 1.1.1.1: docker is installed and running", output
      assert_match "OK 1.1.1.1: logged in to Docker Hub", output
      assert_match "dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} manifest is fetchable", output
      assert_match "OK 1.1.1.1: not running (will be started on deploy)", output
      assert_match "OK 1.1.1.1: ports 80/443 free", output
      assert_match "OK app.example.com: resolves to 1.1.1.1", output
      assert_match(/OK app\.example\.com: served certificate valid until/, output)
      assert_match "ready to deploy", output
    end
  end

  test "doctor with proxy running at current version" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} (minimum #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION})", output
      assert_match "OK 1.1.1.1: ports 80/443 held by the running dash-proxy", output
    end
  end

  test "doctor with proxy version too old" do
    stub_proxy_version "v0.0.1"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "v0.0.1 is older than the minimum #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
  end

  # A host that has not yet been through the stage-3c rename is still running
  # kamal-proxy, which holds 80/443. Reporting that as "in use by another
  # process" fails the doctor and blocks the very deploy that would migrate it —
  # which is what broke the first real 4.0.0 docs deploy.
  test "doctor treats a running legacy proxy as the port holder, not a foreign process" do
    stub_proxy_version nil, legacy: Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "held by the running kamal-proxy", output
      assert_match "replaced on the next deploy", output
      assert_no_match(/already in use by another process/, output)
      assert_match "ready to deploy", output
    end
  end

  # The version check should name what is actually running, rather than
  # reporting "not running" because it only ever looked at dash-proxy.
  test "doctor reports a running legacy proxy by name" do
    stub_proxy_version nil, legacy: Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "kamal-proxy", output
      assert_match(/renamed to dash-proxy on the next deploy/, output)
    end
  end

  # With no proxy of either name, an occupied port is still a real failure.
  test "doctor with ports in use" do
    stub_proxy_version nil
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "80, 443 already in use by another process"
  end

  test "doctor with unresolvable domain" do
    stub_domain_resolution to: []
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "app.example.com: does not resolve"
  end

  test "doctor with domain resolving elsewhere warns" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5, expected one of 1.1.1.1", output
      assert_match "ready to deploy", output
    end
  end

  # "does not resolve" and "resolves elsewhere" are the two states a DNS cutover
  # passes through, and in both an ACME certificate simply cannot be issued yet.
  # Saying so — and that the proxy picks it up by itself — is the difference
  # between an operator waiting confidently and asking someone whether it broke.
  test "doctor explains that an unresolvable ACME domain cannot be certified yet" do
    stub_domain_resolution to: []
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "app.example.com: does not resolve"
    assert_includes exception.message, "no certificate can be issued until it points here"
    assert_includes exception.message, "the proxy issues automatically once it does"
  end

  test "doctor explains the certificate wait when an ACME domain resolves elsewhere" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5, expected one of 1.1.1.1", output
      assert_match "no certificate can be issued until it points here", output
    end
  end

  # A custom certificate is supplied by the operator, so DNS has no bearing on
  # whether it exists. Promising automatic issuance there would be a lie.
  test "doctor does not promise issuance for a custom certificate" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_custom_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5", output
      assert_no_match(/no certificate can be issued/, output)
    end
  end

  test "doctor with expired custom certificate" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_custom_certificate expiring: Time.now - 86_400

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "configured certificate expired on"
  end

  test "doctor with certificate expiring soon warns" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (5 * 86_400)

    run_command("doctor").tap do |output|
      assert_match(/WARN app\.example\.com: served certificate expires in \d+ days/, output)
      assert_match "ready to deploy", output
    end
  end

  test "doctor with unreachable tls endpoint warns" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    Dash::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
      .raises(Errno::ECONNREFUSED.new("Connection refused"))

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: could not check TLS", output
      assert_match "ready to deploy", output
    end
  end

  # The config-time sleep/docker_socket check covers the *current* config; a
  # proxy booted before the socket was added silently lacks the mount until
  # the next reboot, and the failure mode is one hung request when a sleeping
  # service never wakes. The doctor inspects what is actually mounted.
  test "doctor reports a mounted docker socket" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy\n/var/run/docker.sock"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket").tap do |output|
      assert_match "OK 1.1.1.1: docker socket /var/run/docker.sock is mounted", output
    end
  end

  test "doctor fails when sleep is configured but the running proxy lacks the socket mount" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor", fixture: "deploy_with_doctor_socket") }
    assert_includes exception.message, "no /var/run/docker.sock mount"
    assert_includes exception.message, "dash proxy reboot"
  end

  # Without sleep nothing hangs yet, so a missing mount is drift, not breakage.
  test "doctor warns when the socket is configured without sleep and not mounted" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket_only").tap do |output|
      assert_match "WARN 1.1.1.1: the running dash-proxy has no /var/run/docker.sock mount", output
      assert_match "ready to deploy", output
    end
  end

  # Root-equivalent access the config no longer asks for deserves a flag.
  test "doctor warns about a mounted socket the config no longer asks for" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy\n/var/run/docker.sock"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN 1.1.1.1: the running dash-proxy mounts /var/run/docker.sock but the config no longer asks for it", output
      assert_match "ready to deploy", output
    end
  end

  test "doctor reports a boot-time socket when the proxy is not running" do
    stub_proxy_version nil
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket").tap do |output|
      assert_match "OK 1.1.1.1: docker socket /var/run/docker.sock will be mounted on boot", output
    end
  end

  test "doctor stays quiet about sockets when none is configured or mounted" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: no docker socket configured or mounted", output
    end
  end

  test "doctor with local registry skips login" do
    run_command("doctor", fixture: "deploy_with_local_registry").tap do |output|
      assert_match "OK 1.1.1.1: local registry, no login required", output
      assert_match "OK 1.1.1.2: local registry, no login required", output
    end
  end

  test "doctor with unreachable host reports ssh failure" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(SocketError.new("getaddrinfo: nodename nor servname provided, or not known"))
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "SSH"
    assert_includes exception.message, "getaddrinfo"
  end

  test "doctor reports the readiness source of every role" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "Readiness", output
      assert_match "OK web: dash-proxy health check /healthz", output
      assert_match "OK pulse: docker healthcheck (options: health-cmd)", output
      assert_match "OK listener: healthcheck /readyz:7434", output
      assert_match "OK ticker: healthcheck (custom cmd)", output
      assert_match "OK prober: healthcheck exec probe (bin/ready-check)", output
      assert_no_match(/WARN prober/, output)
    end
  end

  test "doctor warns about a role with no readiness definition without failing" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "WARN workers: no healthcheck — the old container stops 7s after the new one starts", output
      assert_match "add a `healthcheck:` block, or opt out with `healthcheck: false`", output
      assert_match "ready to deploy", output
    end
  end

  test "doctor accepts a role that explicitly opted out of a healthcheck" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "OK silent: healthcheck: false — accepted 2s after the container starts", output
      assert_no_match(/WARN silent/, output)
    end
  end

  test "doctor still reports readiness when the hosts are unreachable" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(SocketError.new("getaddrinfo: nodename nor servname provided, or not known"))

    output = stdouted do
      assert_raises(Dash::Cli::DoctorError) do
        with_argv([ "doctor", "-c", "test/fixtures/deploy_with_readiness_sources.yml" ]) { Dash::Cli::Main.start }
      end
    end

    assert_match "WARN workers: no healthcheck", output
  end

  private
    def run_command(*command, fixture: "deploy_with_doctor")
      with_argv([ *command, "-c", "test/fixtures/#{fixture}.yml" ]) do
        stdouted { Dash::Cli::Main.start }
      end
    end

    def stub_proxy_version(version, legacy: nil)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(*PROXY_VERSION_CAPTURE_ARGS)
        .returns(version.to_s)

      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(*LEGACY_PROXY_VERSION_CAPTURE_ARGS)
        .returns(legacy.to_s)

      # A running proxy also gets its mounts inspected; default to none so
      # tests that do not care about the socket check stay quiet. Call
      # stub_proxy_mounts after this to override.
      stub_proxy_mounts ""
    end

    def stub_proxy_mounts(destinations)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :inspect, "dash-proxy", "--format", "'{{range .Mounts}}{{println .Destination}}{{end}}'", raise_on_non_zero_exit: false)
        .returns(destinations)
    end

    def stub_domain_resolution(to:)
      Resolv.stubs(:getaddresses).with("app.example.com").returns(to)
    end

    def stub_served_certificate(expiring:)
      Dash::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
        .returns(generate_certificate(not_after: expiring))
    end

    def stub_custom_certificate(expiring:)
      Dash::Configuration::Proxy.any_instance.stubs(:custom_ssl_certificate?).returns(true)
      Dash::Configuration::Proxy.any_instance.stubs(:certificate_pem_content)
        .returns(generate_certificate(not_after: expiring).to_pem)
    end

    def generate_certificate(not_after:)
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse("/CN=app.example.com")
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 3600
      certificate.not_after = not_after
      certificate.sign(key, OpenSSL::Digest::SHA256.new)
      certificate
    end
end
