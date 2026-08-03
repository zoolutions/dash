require "test_helper"

class ConfigurationProxyAcmeTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"
  end

  test "no acme block leaves the run command untouched" do
    assert_equal "kamal-proxy run --recheck-targets-on-restore", run_config({}).run_command
  end

  test "acme settings become kamal-proxy run flags" do
    run = run_config \
      "email" => "admin@example.com",
      "dns_provider" => "cloudflare",
      "directory" => "https://acme-staging-v02.api.letsencrypt.org/directory"

    assert_equal "kamal-proxy run --recheck-targets-on-restore " \
      "--acme-email=\"admin@example.com\" --acme-dns-provider=\"cloudflare\" " \
      "--acme-directory=\"https://acme-staging-v02.api.letsencrypt.org/directory\"",
      run.run_command
  end

  # Cobra only reads a boolean flag's value in --flag=false form. `--acme-http-fallback false`
  # would set the flag true and leave a stray positional argument behind, so an operator
  # opting out would silently get the default.
  test "boolean acme settings render with an explicit value when false" do
    run = run_config "email" => "admin@example.com", "prefer_wildcard" => false, "http_fallback" => false

    assert_match %(--acme-prefer-wildcard="false"), run.run_command
    assert_match %(--acme-http-fallback="false"), run.run_command
  end

  test "boolean acme settings render as bare flags when true" do
    run = run_config "email" => "admin@example.com", "prefer_wildcard" => true, "http_fallback" => true

    assert_match(/--acme-prefer-wildcard(?!=)/, run.run_command)
    assert_match(/--acme-http-fallback(?!=)/, run.run_command)
  end

  test "credentials are read from secrets and never reach the command line" do
    with_test_secrets("secrets" => "LOOPIA_API_USER=user\nLOOPIA_API_PASSWORD=s3cr3t") do
      run = run_config "email" => "admin@example.com", "dns_provider" => "auto",
        "credentials" => [ "LOOPIA_API_USER", "LOOPIA_API_PASSWORD" ]

      assert_equal "LOOPIA_API_USER=user\nLOOPIA_API_PASSWORD=s3cr3t\n", run.secrets_io.string
      assert_equal ".kamal/proxy/secrets.env", run.secrets_path

      assert_includes run.docker_options_args, "--env-file"
      assert_includes run.docker_options_args, ".kamal/proxy/secrets.env"

      assert_no_match(/s3cr3t/, run.run_command)
      assert_no_match(/s3cr3t/, run.docker_options_args.join(" "))
    end
  end

  test "no credentials means no env file" do
    run = run_config "email" => "admin@example.com"

    assert_not_includes run.docker_options_args, "--env-file"
  end

  test "a missing credential secret fails" do
    with_test_secrets("secrets" => "OTHER=value") do
      run = run_config "email" => "admin@example.com", "credentials" => [ "LOOPIA_API_PASSWORD" ]

      error = assert_raises(Kamal::ConfigurationError) { run.secrets_io }
      assert_match "Secret 'LOOPIA_API_PASSWORD' not found", error.message
    end
  end

  test "config_digest is unchanged for a config with no acme block" do
    config = Kamal::Configuration.new(base_deploy)

    assert_equal Kamal::Configuration::Proxy::Run.digest(
      "ghcr.io/mhenrixon/kamal-proxy:#{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}",
      "kamal-proxy run --recheck-targets-on-restore",
      *Kamal::Configuration::Proxy::Run.new(config, run_config: {}).docker_options_args
    ), Kamal::Configuration::Proxy::Run.new(config, run_config: {}).config_digest
  end

  test "config_digest changes when acme settings change" do
    base = run_config({}).config_digest

    assert_not_equal base, run_config("email" => "admin@example.com").config_digest
    assert_not_equal run_config("email" => "admin@example.com").config_digest,
      run_config("email" => "admin@example.com", "dns_provider" => "cloudflare").config_digest
  end

  test "config_digest changes when the credential names change" do
    with_test_secrets("secrets" => "ONE=1\nTWO=2") do
      one = run_config "email" => "admin@example.com", "credentials" => [ "ONE" ]
      two = run_config "email" => "admin@example.com", "credentials" => [ "TWO" ]

      assert_not_equal one.config_digest, two.config_digest
    end
  end

  test "an unknown dns_provider fails validation naming the supported providers" do
    error = assert_raises(Kamal::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => "loopia"
    end

    assert_equal "proxy/run/acme: unsupported dns_provider 'loopia'. " \
      "Supported providers: #{Kamal::Configuration::Proxy::Acme::DNS_PROVIDERS.join(", ")}", error.message
  end

  test "provider aliases and canonical names pass validation" do
    assert validated_config("email" => "admin@example.com", "dns_provider" => "route53")
    assert validated_config("email" => "admin@example.com", "dns_provider" => "r53")
    assert validated_config("email" => "admin@example.com", "dns_provider" => "CloudFlare")
  end

  test "acme requires an email" do
    error = assert_raises(Kamal::ConfigurationError) do
      validated_config "dns_provider" => "cloudflare"
    end

    assert_equal "proxy/run/acme: Missing email setting (required when acme is set)", error.message
  end

  test "credentials must name secrets" do
    error = assert_raises(Kamal::ConfigurationError) do
      validated_config "email" => "admin@example.com", "credentials" => [ { "LOOPIA_API_USER" => "user" } ]
    end

    assert_equal "proxy/run/acme/credentials/0: should be a string", error.message
  end

  test "validate_secrets! resolves the acme credentials before any host is contacted" do
    with_test_secrets("secrets" => "OTHER=value") do
      config = Kamal::Configuration.new base_deploy.merge(
        proxy: { "host" => "example.com", "run" => { "acme" => {
          "email" => "admin@example.com", "credentials" => [ "CF_API_TOKEN" ]
        } } }
      )

      error = assert_raises(Kamal::ConfigurationError) { config.validate_secrets! }
      assert_match "Secret 'CF_API_TOKEN' not found", error.message
    end
  end

  test "an unknown acme key fails validation" do
    error = assert_raises(Kamal::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_challenge" => true
    end

    assert_equal "proxy/run/acme: unknown key: dns_challenge", error.message
  end

  private
    def validated_config(acme_config)
      Kamal::Configuration.new base_deploy.merge(
        proxy: { "host" => "example.com", "run" => { "acme" => acme_config } }
      )
    end

    def run_config(acme_config)
      config = Kamal::Configuration.new(base_deploy)
      run = acme_config.present? ? { "acme" => acme_config } : {}

      Kamal::Configuration::Proxy::Run.new(config, run_config: run)
    end

    def base_deploy
      {
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ]
      }
    end
end
