# ACME configuration for the kamal-proxy container, including the DNS-01
# challenge credentials.
#
# Everything here except the credentials becomes a `kamal-proxy run` flag, so it
# lands in the run command and therefore in Proxy::Run#config_digest — changing
# the block reboots the proxy on the next deploy.
#
# Credentials go the other way, through an env file uploaded at mode 0600. A DNS
# API token can rewrite your zone; `docker run --env TOKEN=...` would put it in
# the host's process listing and in kamal's own audit log.
class Dash::Configuration::Proxy::Acme
  # The canonical provider names kamal-proxy MINIMUM_VERSION advertises. Kept in
  # step with the proxy by test/proxy_flag_coverage_test.rb, which compares this
  # list against the manifest bin/sync-proxy-flags generates from the image.
  DNS_PROVIDERS = %w[
    auto cloudflare digitalocean gcloud godaddy hetzner namecheap none route53 vultr
  ].freeze

  # Short forms kamal-proxy's ParseProviderName accepts but does not advertise,
  # so they cannot be generated from --help and are not drift-checked.
  DNS_PROVIDER_ALIASES = %w[ cf do gcp google googledns gd hz nc aws r53 vr ].freeze

  SUPPORTED_DNS_PROVIDERS = (DNS_PROVIDERS + DNS_PROVIDER_ALIASES).freeze

  attr_reader :acme_config, :secrets

  def initialize(acme_config:, secrets:)
    @acme_config = acme_config || {}
    @secrets = secrets
  end

  def configured?
    acme_config.present?
  end

  def credential_names
    Array(acme_config["credentials"])
  end

  def credentials?
    credential_names.any?
  end

  # The resolved credentials, for the shared proxy secrets env file that
  # Proxy::Run#secrets_io assembles (cache store and acme travel together).
  def credentials_env
    credential_names.to_h { |name| [ name, secrets[name] ] }
  end

  # Rendered with `=` rather than a space, unlike the rest of the run command:
  # Cobra only reads a boolean flag's value in --flag=false form, so
  # `--acme-http-fallback false` would set the flag true and leave "false" behind
  # as a stray argument. Both booleans default to true in the proxy, which makes
  # false the value an operator actually writes.
  def run_command_args
    Dash::Utils.optionize(run_command_options, with: "=")
  end

  # compact, not compact_blank: false is a meaningful value for both booleans.
  def run_command_options
    {
      "acme-email": acme_config["email"],
      "acme-dns-provider": dns_provider_entries,
      "acme-directory": acme_config["directory"],
      "acme-prefer-wildcard": acme_config["prefer_wildcard"],
      "acme-http-fallback": acme_config["http_fallback"],
      "acme-release-probe-interval": Dash::Utils.seconds_duration(acme_config["release_probe_interval"])
    }.compact
  end

  private
    # The hash form pins zones to the DNS host that serves them; `default`
    # covers unmatched zones. kamal-proxy takes repeatable --acme-dns-provider
    # entries — zone=provider pairs plus at most one bare default — so the hash
    # becomes an array and Utils.optionize repeats the flag. The string form
    # passes through untouched and keeps meaning what it always has.
    def dns_provider_entries
      provider = acme_config["dns_provider"]
      return provider unless provider.is_a?(Hash)

      zones, default = provider.partition { |zone, _| zone != "default" }

      [ *zones.map { |zone, zone_provider| "#{zone}=#{zone_provider}" }, *default.map(&:last) ]
    end
end
