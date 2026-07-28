require_relative "cli_test_case"

class CliDoctorTest < CliTestCase
  PROXY_VERSION_CAPTURE_ARGS = [ :docker, :inspect, "kamal-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'" ]

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
      assert_match "kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} manifest is fetchable", output
      assert_match "OK 1.1.1.1: not running (will be started on deploy)", output
      assert_match "OK 1.1.1.1: ports 80/443 free", output
      assert_match "OK app.example.com: resolves to 1.1.1.1", output
      assert_match(/OK app\.example\.com: served certificate valid until/, output)
      assert_match "ready to deploy", output
    end
  end

  test "doctor with proxy running at current version" do
    stub_proxy_version Kamal::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: #{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION} (minimum #{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION})", output
      assert_match "OK 1.1.1.1: ports 80/443 held by the running kamal-proxy", output
    end
  end

  test "doctor with proxy version too old" do
    stub_proxy_version "v0.0.1"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Kamal::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "v0.0.1 is older than the minimum #{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}"
  end

  test "doctor with ports in use" do
    stub_proxy_version nil
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Kamal::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "80, 443 already in use by another process"
  end

  test "doctor with unresolvable domain" do
    stub_domain_resolution to: []
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Kamal::Cli::DoctorError) { run_command("doctor") }
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

  test "doctor with expired custom certificate" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_custom_certificate expiring: Time.now - 86_400

    exception = assert_raises(Kamal::Cli::DoctorError) { run_command("doctor") }
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
    Kamal::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
      .raises(Errno::ECONNREFUSED.new("Connection refused"))

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: could not check TLS", output
      assert_match "ready to deploy", output
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

    exception = assert_raises(Kamal::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "SSH"
    assert_includes exception.message, "getaddrinfo"
  end

  private
    def run_command(*command, fixture: "deploy_with_doctor")
      with_argv([ *command, "-c", "test/fixtures/#{fixture}.yml" ]) do
        stdouted { Kamal::Cli::Main.start }
      end
    end

    def stub_proxy_version(version)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(*PROXY_VERSION_CAPTURE_ARGS)
        .returns(version.to_s)
    end

    def stub_domain_resolution(to:)
      Resolv.stubs(:getaddresses).with("app.example.com").returns(to)
    end

    def stub_served_certificate(expiring:)
      Kamal::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
        .returns(generate_certificate(not_after: expiring))
    end

    def stub_custom_certificate(expiring:)
      Kamal::Configuration::Proxy.any_instance.stubs(:custom_ssl_certificate?).returns(true)
      Kamal::Configuration::Proxy.any_instance.stubs(:certificate_pem_content)
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
