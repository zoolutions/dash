require "test_helper"

# kamal-proxy grows flags faster than deploy.yml grows keys, and nothing noticed:
# 23 `feat` commits landed between v0.9.2.2 and v1.0.0.0 and the gem's config
# surface never moved. A flag the gem cannot emit is a feature that ships in the
# image and is unreachable from deploy.yml.
#
# So: every flag kamal-proxy accepts must either be emitted by the gem, or be
# waived here with a reason. New flags fail the build at the MINIMUM_VERSION bump
# — the moment someone is already thinking about gem/proxy compatibility.
#
# The flag list is generated, not hand-written: see bin/sync-proxy-flags, which
# reads Cobra's own --help output. (A regex over the Go source misses flags
# registered via Int64Var and friends — that is not hypothetical, it is how the
# gap was under-counted in the first place.)
class ProxyFlagCoverageTest < ActiveSupport::TestCase
  MANIFEST = YAML.load_file(File.expand_path("fixtures/kamal_proxy_flags.yml", __dir__))

  # Flags that are not deploy.yml's business — a decision, not a backlog.
  NEVER_EXPOSED = {
    "deploy" => {
      "force" => "CLI-level concern (kamal proxy deploy), not operator config"
    },
    "run" => {
      "http-port" => "the gem publishes host:container ports via docker; the proxy listens on its default inside",
      "https-port" => "same as --http-port",
      "data-dir" => "fixed by the kamal-proxy-config volume mount in Kamal::Commands::Proxy#run"
    }
  }.freeze

  # Flags an R7 issue will expose (mhenrixon/kamal#13). This is a backlog, not a
  # decision: when an issue lands, delete its entry here and add the key to
  # test/fixtures/deploy_with_every_proxy_option.yml. The flag then has to show up
  # in the generated command or this test fails — which is the point. The waiver
  # list shrinking to empty is what "R7 is done" means.
  R7_BACKLOG = {
    "deploy" => {
      74 => %w[ tls-on-demand-url tls-client-ca-path tls-acme-cache-path ],
      75 => %w[ cache cache-allow-set-cookie cache-max-body cache-max-ttl cache-max-variants
                cache-vary-cookie cache-vary-header ],
      76 => %w[ compress compress-content-type compress-min-length ],
      77 => %w[ rate-limit rate-limit-burst rate-limit-exempt allow-ip trusted-proxy client-ip-header ],
      78 => %w[ add-request-header add-response-header set-request-header set-response-header
                remove-request-header remove-response-header redirect rewrite canonical-host
                scope-cookie-paths intercept-errors ],
      79 => %w[ session-affinity session-affinity-cookie sleep-after sleep-container wake-timeout ],
      80 => %w[ target-dial-timeout target-disable-keep-alives target-idle-conn-timeout
                target-max-conns target-max-idle-conns target-try-duration target-try-interval
                request-timeout path-request-timeout ],
      81 => %w[ exclude-metrics-path ]
    },
    "run" => {
      75 => %w[ cache-store cache-store-timeout cache-memory-size cache-lease-ttl cache-lease-wait ],
      81 => %w[ docker-socket http3 idle-timeout ignore-restore-errors log-format metrics-allow-ip
                min-tls proxy-protocol proxy-protocol-allow-ip read-header-timeout read-timeout
                reuse-port shutdown-timeout trace-context write-timeout ]
    }
  }.freeze

  WAIVED = NEVER_EXPOSED.to_h { |subcommand, never|
    backlog = R7_BACKLOG.fetch(subcommand).flat_map { |issue, flags|
      flags.map { |flag| [ flag, "R7 backlog — mhenrixon/kamal##{issue}" ] }
    }.to_h

    [ subcommand, never.merge(backlog) ]
  }.freeze

  test "the flag manifest tracks MINIMUM_VERSION" do
    assert_equal Kamal::Configuration::Proxy::Run::MINIMUM_VERSION, MANIFEST["proxy_version"], <<~MESSAGE
      test/fixtures/kamal_proxy_flags.yml was generated for kamal-proxy #{MANIFEST["proxy_version"]},
      but MINIMUM_VERSION is now #{Kamal::Configuration::Proxy::Run::MINIMUM_VERSION}.

      Refresh it:  bin/sync-proxy-flags

      Then re-run this suite — any flag the new proxy added will be reported below
      as unmapped, which is the point: decide whether to expose it or waive it.
    MESSAGE
  end

  test "every kamal-proxy deploy flag is exposed in deploy.yml or waived" do
    assert_covered "deploy", emitted_deploy_flags
  end

  test "every kamal-proxy run flag is exposed in deploy.yml or waived" do
    assert_covered "run", emitted_run_flags
  end

  # Unlike a flag the gem cannot emit, a provider the gem does not know is not a
  # missing feature — it is a rejected deploy. proxy/run/acme/dns_provider is
  # validated against Acme::DNS_PROVIDERS, so a provider kamal-proxy grew and the
  # gem did not fails config validation for an operator who is holding it right.
  test "the gem's DNS provider allowlist matches what kamal-proxy advertises" do
    assert_equal MANIFEST.fetch("acme_dns_providers").sort,
      Kamal::Configuration::Proxy::Acme::DNS_PROVIDERS.sort, <<~MESSAGE
        kamal-proxy #{MANIFEST["proxy_version"]} and Kamal::Configuration::Proxy::Acme::DNS_PROVIDERS
        disagree about which DNS providers exist.

        Refresh the manifest (bin/sync-proxy-flags), then bring DNS_PROVIDERS in
        line with it. Providers the proxy gained are ones an operator can now
        configure and the gem would reject; providers it lost are ones the gem
        still accepts and the proxy will silently ignore.

        Short aliases (cf, r53, ...) live in DNS_PROVIDER_ALIASES — kamal-proxy
        accepts them but does not advertise them, so they are not checked here.
      MESSAGE
  end

  test "no waiver names a flag kamal-proxy no longer accepts" do
    WAIVED.each do |subcommand, waivers|
      stale = waivers.keys - MANIFEST.fetch("flags").fetch(subcommand)

      assert_empty stale, <<~MESSAGE
        These #{subcommand} waivers name flags kamal-proxy #{MANIFEST["proxy_version"]} does not
        accept: #{stale.join(", ")}.

        The flag was renamed or removed upstream. Drop the waiver, and check
        whether the gem still emits something the proxy will reject.
      MESSAGE
    end
  end

  private
    def assert_covered(subcommand, emitted)
      flags = MANIFEST.fetch("flags").fetch(subcommand)
      uncovered = flags - emitted - WAIVED.fetch(subcommand).keys

      assert_empty uncovered, <<~MESSAGE
        kamal-proxy #{MANIFEST["proxy_version"]} accepts #{uncovered.size} #{subcommand} flag(s) the gem can
        neither emit nor account for:

        #{uncovered.map { |flag| "  --#{flag}" }.join("\n")}

        For each one, either:

          * expose it — add the deploy.yml key, wire it into
            #{subcommand == "deploy" ? "Kamal::Configuration::Proxy#deploy_options" : "Kamal::Configuration::Proxy::Run#run_command_options"},
            and set it in test/fixtures/deploy_with_every_proxy_option.yml so this
            check proves it is really wired; or

          * waive it — add it to WAIVED["#{subcommand}"] with the reason it does not
            belong in deploy.yml.

        Coverage now: #{emitted.size} emitted + #{WAIVED.fetch(subcommand).size} waived of #{flags.size}.
      MESSAGE
    end

    # Flags the gem actually produces, generated from the maximal fixture rather
    # than read off the deploy_options hash — a key that resolves to nil emits
    # nothing, and should not count as covered.
    def emitted_deploy_flags
      flag_names maximal_config.role(:web).proxy.deploy_command_args(target: "1.1.1.1")
    end

    def emitted_run_flags
      flag_names maximal_config.proxy_run("1.1.1.1").run_command
    end

    def flag_names(args)
      Array(args).join(" ").scan(/--([a-z0-9-]+)/).flatten.uniq
    end

    def maximal_config
      @maximal_config ||= Kamal::Configuration.create_from \
        config_file: Pathname.new(File.expand_path("fixtures/deploy_with_every_proxy_option.yml", __dir__))
    end
end
