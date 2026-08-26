require "test_helper"

# dash-proxy grows flags faster than deploy.yml grows keys, and nothing noticed:
# 23 `feat` commits landed between v0.9.2.2 and v1.0.0.0 and the gem's config
# surface never moved. A flag the gem cannot emit is a feature that ships in the
# image and is unreachable from deploy.yml.
#
# So: every flag dash-proxy accepts must either be emitted by the gem, or be
# waived here with a reason. New flags fail the build at the MINIMUM_VERSION bump
# — the moment someone is already thinking about gem/proxy compatibility.
#
# The flag list is generated, not hand-written: see bin/sync-proxy-flags, which
# reads Cobra's own --help output. (A regex over the Go source misses flags
# registered via Int64Var and friends — that is not hypothetical, it is how the
# gap was under-counted in the first place.)
class ProxyFlagCoverageTest < ActiveSupport::TestCase
  MANIFEST = YAML.load_file(File.expand_path("fixtures/kamal_proxy_flags.yml", __dir__))

  MAXIMAL_FIXTURES = %w[ deploy_with_every_proxy_option deploy_with_on_demand_tls ].freeze

  # Flags that are not deploy.yml's business — a decision, not a backlog.
  NEVER_EXPOSED = {
    "deploy" => {
      "force" => "CLI-level concern (dash proxy deploy), not operator config",
      "tls-acme-cache-path" => "cut for 3.0 (#93 D4) - dash-proxy's default already persists ACME assets in the dash-proxy-config volume, so the knob only offered ways to break that",
      "scope-cookie-paths" => "cut for 3.0 (#93 D4) - niche cookie-path rewriting under path_prefix; re-expose post-3.0 if someone asks for it"
    },
    "run" => {
      "http-port" => "the gem publishes host:container ports via docker; the proxy listens on its default inside",
      "https-port" => "same as --http-port",
      "data-dir" => "fixed by the dash-proxy-config volume mount in Dash::Commands::Proxy#run",
      "cache-store" => "delivered as CACHE_STORE via the 0600 proxy secrets env file - a store URL may embed credentials that must stay out of process listings and the audit log",
      "cache-lease-ttl" => "cut for 3.0 (#93 D4) - cross-node coalescing tuning with sane proxy defaults; proxy/run/flags remains the escape hatch",
      "cache-lease-wait" => "same as --cache-lease-ttl"
    }
  }.freeze

  # Flags an R7 issue will expose (zoolutions/dash#13). This is a backlog, not a
  # decision: when an issue lands, delete its entry here and add the key to
  # test/fixtures/deploy_with_every_proxy_option.yml. The flag then has to show up
  # in the generated command or this test fails — which is the point. The waiver
  # list shrinking to empty is what "R7 is done" means.
  #
  # It is empty. Every flag dash-proxy accepts is now either emitted from a
  # deploy.yml key or waived above with a reason. A new proxy release that adds
  # one fails this test at the MINIMUM_VERSION bump, which is the only moment
  # anyone is thinking about gem/proxy compatibility.
  #
  # Do NOT close that gap with proxy/run/flags. The escape hatch forwards
  # anything, so putting a new flag in the fixture's `flags:` would turn this
  # check green while leaving the flag unreachable by name — exactly the silence
  # this test exists to break. Give it a key.
  R7_BACKLOG = {
    "deploy" => {},
    "run" => {}
  }.freeze

  WAIVED = NEVER_EXPOSED.to_h { |subcommand, never|
    backlog = R7_BACKLOG.fetch(subcommand).flat_map { |issue, flags|
      flags.map { |flag| [ flag, "R7 backlog — zoolutions/dash##{issue}" ] }
    }.to_h

    [ subcommand, never.merge(backlog) ]
  }.freeze

  test "the flag manifest tracks MINIMUM_VERSION" do
    assert_equal Dash::Configuration::Proxy::Run::MINIMUM_VERSION, MANIFEST["proxy_version"], <<~MESSAGE
      test/fixtures/kamal_proxy_flags.yml was generated for dash-proxy #{MANIFEST["proxy_version"]},
      but MINIMUM_VERSION is now #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}.

      Refresh it:  bin/sync-proxy-flags

      Then re-run this suite — any flag the new proxy added will be reported below
      as unmapped, which is the point: decide whether to expose it or waive it.
    MESSAGE
  end

  test "every dash-proxy deploy flag is exposed in deploy.yml or waived" do
    assert_covered "deploy", emitted_deploy_flags
  end

  test "every dash-proxy run flag is exposed in deploy.yml or waived" do
    assert_covered "run", emitted_run_flags
  end

  # Unlike a flag the gem cannot emit, a provider the gem does not know is not a
  # missing feature — it is a rejected deploy. proxy/run/acme/dns_provider is
  # validated against Acme::DNS_PROVIDERS, so a provider dash-proxy grew and the
  # gem did not fails config validation for an operator who is holding it right.
  test "the gem's DNS provider allowlist matches what dash-proxy advertises" do
    assert_equal MANIFEST.fetch("acme_dns_providers").sort,
      Dash::Configuration::Proxy::Acme::DNS_PROVIDERS.sort, <<~MESSAGE
        dash-proxy #{MANIFEST["proxy_version"]} and Dash::Configuration::Proxy::Acme::DNS_PROVIDERS
        disagree about which DNS providers exist.

        Refresh the manifest (bin/sync-proxy-flags), then bring DNS_PROVIDERS in
        line with it. Providers the proxy gained are ones an operator can now
        configure and the gem would reject; providers it lost are ones the gem
        still accepts and the proxy will silently ignore.

        Short aliases (cf, r53, ...) live in DNS_PROVIDER_ALIASES — dash-proxy
        accepts them but does not advertise them, so they are not checked here.
      MESSAGE
  end

  test "no waiver names a flag dash-proxy no longer accepts" do
    WAIVED.each do |subcommand, waivers|
      stale = waivers.keys - MANIFEST.fetch("flags").fetch(subcommand)

      assert_empty stale, <<~MESSAGE
        These #{subcommand} waivers name flags dash-proxy #{MANIFEST["proxy_version"]} does not
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
        dash-proxy #{MANIFEST["proxy_version"]} accepts #{uncovered.size} #{subcommand} flag(s) the gem can
        neither emit nor account for:

        #{uncovered.map { |flag| "  --#{flag}" }.join("\n")}

        For each one, either:

          * expose it — add the deploy.yml key, wire it into
            #{subcommand == "deploy" ? "Dash::Configuration::Proxy#deploy_options" : "Dash::Configuration::Proxy::Run#run_command_options"},
            and set it in test/fixtures/deploy_with_every_proxy_option.yml so this
            check proves it is really wired; or

          * waive it — add it to WAIVED["#{subcommand}"] with the reason it does not
            belong in deploy.yml.

        Coverage now: #{emitted.size} emitted + #{WAIVED.fetch(subcommand).size} waived of #{flags.size}.
      MESSAGE
    end

    # Flags the gem actually produces, generated from the maximal fixtures rather
    # than read off the deploy_options hash — a key that resolves to nil emits
    # nothing, and should not count as covered.
    def emitted_deploy_flags
      maximal_configs.flat_map { |config| flag_names config.role(:web).proxy.deploy_command_args(target: "1.1.1.1") }.uniq
    end

    def emitted_run_flags
      maximal_configs.flat_map { |config| flag_names config.proxy_run("1.1.1.1")&.run_command }.uniq
    end

    def flag_names(args)
      Array(args).join(" ").scan(/--([a-z0-9-]+)/).flatten.uniq
    end

    # More than one, because some options are mutually exclusive: dash-proxy
    # forbids on-demand TLS alongside a host list, a custom certificate or
    # ssl_domains, so one fixture cannot hold every key. Coverage is the union.
    def maximal_configs
      @maximal_configs ||= MAXIMAL_FIXTURES.map do |fixture|
        Dash::Configuration.create_from \
          config_file: Pathname.new(File.expand_path("fixtures/#{fixture}.yml", __dir__))
      end
    end
end
