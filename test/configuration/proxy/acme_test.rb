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

  # How often the proxy re-checks held domains, which is what decides how long
  # after a DNS repoint the certificate appears.
  test "release probe interval becomes a duration flag" do
    run = run_config "email" => "admin@example.com", "release_probe_interval" => 30

    assert_match %(--acme-release-probe-interval="30s"), run.run_command
  end

  test "release probe interval accepts a duration string" do
    run = run_config "email" => "admin@example.com", "release_probe_interval" => "5m"

    assert_match %(--acme-release-probe-interval="5m"), run.run_command
  end

  # A negative interval is how the proxy is told to stop release probing at all,
  # so it has to survive rather than be treated as absent.
  test "release probe interval passes a negative value through" do
    run = run_config "email" => "admin@example.com", "release_probe_interval" => "-1s"

    assert_match %(--acme-release-probe-interval="-1s"), run.run_command
  end

  test "no release probe interval leaves the flag off entirely" do
    run = run_config "email" => "admin@example.com"

    assert_no_match(/--acme-release-probe-interval/, run.run_command)
  end

  test "credentials are read from secrets and never reach the command line" do
    with_test_secrets("secrets" => "LOOPIA_API_USER=user\nLOOPIA_API_PASSWORD=s3cr3t") do
      run = run_config "email" => "admin@example.com", "dns_provider" => "auto",
        "credentials" => [ "LOOPIA_API_USER", "LOOPIA_API_PASSWORD" ]

      assert_equal "LOOPIA_API_USER=user\nLOOPIA_API_PASSWORD=s3cr3t\n", run.secrets_io.string
      assert_equal ".dash/proxy/secrets.env", run.secrets_path

      assert_includes run.docker_options_args, "--env-file"
      assert_includes run.docker_options_args, ".dash/proxy/secrets.env"

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

      error = assert_raises(Dash::ConfigurationError) { run.secrets_io }
      assert_match "Secret 'LOOPIA_API_PASSWORD' not found", error.message
    end
  end

  test "config_digest is unchanged for a config with no acme block" do
    config = Dash::Configuration.new(base_deploy)

    assert_equal Dash::Configuration::Proxy::Run.digest(
      "ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}",
      "kamal-proxy run --recheck-targets-on-restore",
      *Dash::Configuration::Proxy::Run.new(config, run_config: {}).docker_options_args
    ), Dash::Configuration::Proxy::Run.new(config, run_config: {}).config_digest
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
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => "loopia"
    end

    assert_equal "proxy/run/acme: unsupported dns_provider 'loopia'. " \
      "Supported providers: #{Dash::Configuration::Proxy::Acme::DNS_PROVIDERS.join(", ")}", error.message
  end

  test "provider aliases and canonical names pass validation" do
    assert validated_config("email" => "admin@example.com", "dns_provider" => "route53")
    assert validated_config("email" => "admin@example.com", "dns_provider" => "r53")
    assert validated_config("email" => "admin@example.com", "dns_provider" => "CloudFlare")
  end

  # Per-zone DNS-01 providers: the hash form pins zones to the DNS host that
  # serves them, `default` covers unmatched zones. Wire format is repeatable
  # --acme-dns-provider entries — zone=provider pairs plus one bare default.
  test "a dns_provider hash becomes repeatable zone=provider flags with the default last" do
    run = run_config "email" => "admin@example.com", "dns_provider" => {
      "platform.example" => "cloudflare", "legacy.example" => "hetzner", "default" => "route53"
    }

    assert_equal "kamal-proxy run --recheck-targets-on-restore " \
      "--acme-email=\"admin@example.com\" " \
      "--acme-dns-provider=\"platform.example=cloudflare\" " \
      "--acme-dns-provider=\"legacy.example=hetzner\" " \
      "--acme-dns-provider=\"route53\"",
      run.run_command
  end

  test "a dns_provider hash without a default emits only zone entries" do
    run = run_config "email" => "admin@example.com", "dns_provider" => { "platform.example" => "cloudflare" }

    assert_match %(--acme-dns-provider="platform.example=cloudflare"), run.run_command
    assert_no_match(/--acme-dns-provider="cloudflare"/, run.run_command)
  end

  test "an unknown provider in a dns_provider hash fails validation naming the zone" do
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => {
        "platform.example" => "loopia", "default" => "hetzner"
      }
    end

    assert_equal "proxy/run/acme: unsupported dns_provider 'loopia' for 'platform.example'. " \
      "Supported providers: #{Dash::Configuration::Proxy::Acme::DNS_PROVIDERS.join(", ")}", error.message
  end

  test "provider aliases pass validation in a dns_provider hash" do
    assert validated_config("email" => "admin@example.com", "dns_provider" => {
      "platform.example" => "cf", "default" => "r53"
    })
  end

  # The wire format cuts zone=provider at the first '=', so an '=' in a zone
  # would silently build an entry for a different zone.
  test "a zone containing an equals sign is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => { "bad=zone.example" => "cloudflare" }
    end

    assert_match "cannot contain '='", error.message
  end

  test "an empty dns_provider hash is rejected" do
    assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => {}
    end
  end

  # A malformed zone key would emit an --acme-dns-provider entry no zone ever
  # matches, so the misconfiguration surfaces as certificates that never issue.
  test "a non-string or whitespace zone key is rejected" do
    [ 123, "", "zone with spaces.example" ].each do |zone|
      error = assert_raises(Dash::ConfigurationError, "expected zone #{zone.inspect} to be rejected") do
        validated_config "email" => "admin@example.com", "dns_provider" => { zone => "cloudflare" }
      end

      assert_match "must be a non-empty string without whitespace", error.message
    end
  end

  test "a non-string provider in a dns_provider hash is rejected" do
    assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_provider" => { "platform.example" => true }
    end
  end

  test "config_digest changes when a zone mapping changes" do
    one = run_config "email" => "admin@example.com", "dns_provider" => { "a.example" => "cloudflare", "default" => "hetzner" }
    two = run_config "email" => "admin@example.com", "dns_provider" => { "a.example" => "route53", "default" => "hetzner" }

    assert_not_equal one.config_digest, two.config_digest
  end

  test "acme requires an email" do
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "dns_provider" => "cloudflare"
    end

    assert_equal "proxy/run/acme: Missing email setting (required when acme is set)", error.message
  end

  test "credentials must name secrets" do
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "credentials" => [ { "LOOPIA_API_USER" => "user" } ]
    end

    assert_equal "proxy/run/acme/credentials/0: should be a string", error.message
  end

  test "validate_secrets! resolves the acme credentials before any host is contacted" do
    with_test_secrets("secrets" => "OTHER=value") do
      config = Dash::Configuration.new base_deploy.merge(
        proxy: { "host" => "example.com", "run" => { "acme" => {
          "email" => "admin@example.com", "credentials" => [ "CF_API_TOKEN" ]
        } } }
      )

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match "Secret 'CF_API_TOKEN' not found", error.message
    end
  end

  test "an unknown acme key fails validation" do
    error = assert_raises(Dash::ConfigurationError) do
      validated_config "email" => "admin@example.com", "dns_challenge" => true
    end

    assert_equal "proxy/run/acme: unknown key: dns_challenge", error.message
  end

  private
    def validated_config(acme_config)
      Dash::Configuration.new base_deploy.merge(
        proxy: { "host" => "example.com", "run" => { "acme" => acme_config } }
      )
    end

    def run_config(acme_config)
      config = Dash::Configuration.new(base_deploy)
      run = acme_config.present? ? { "acme" => acme_config } : {}

      Dash::Configuration::Proxy::Run.new(config, run_config: run)
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
