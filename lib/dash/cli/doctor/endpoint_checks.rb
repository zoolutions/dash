require "resolv"
require "socket"
require "openssl"

# Local (no SSH) readiness checks for the domains dash-proxy will serve:
# DNS resolution against the configured hosts and TLS certificate expiry.
class Dash::Cli::Doctor::EndpointChecks
  CERTIFICATE_EXPIRY_WARN_DAYS = 14
  SECONDS_PER_DAY = 86_400
  TLS_CONNECT_TIMEOUT = 5

  def run
    dns_results + certificate_results
  end

  private
    def result(check, target, status, detail)
      Dash::Cli::Doctor::Result.new(check, target, status, detail)
    end

    # Roles and accessories that run behind the proxy with custom domains.
    def proxied_units
      @proxied_units ||= (DASH.roles + DASH.config.proxy_accessories).select do |unit|
        unit.running_proxy? && unit.proxy.hosts.any?
      end
    end

    def dns_results
      proxied_units.flat_map do |unit|
        unit.proxy.hosts.map { |domain| dns_check(domain, unit.hosts, acme_issued: acme_issued?(unit)) }
      end
    end

    # Whether this unit's certificate comes from ACME rather than the operator.
    # Only then does where the domain points decide whether a certificate can
    # exist — a supplied certificate is unaffected by DNS.
    def acme_issued?(unit)
      unit.proxy.ssl? && !unit.proxy.custom_ssl_certificate?
    end

    # The two states a DNS cutover passes through — not resolving yet, and still
    # resolving to the old host — are exactly when an operator wonders whether
    # something is broken. Nothing is: the proxy refuses to spend an ACME order
    # it cannot win, re-checks held domains, and issues once the domain arrives.
    ISSUANCE_PENDING = "no certificate can be issued until it points here, and the proxy issues automatically once it does".freeze

    def with_issuance_note(detail, acme_issued)
      acme_issued ? "#{detail} - #{ISSUANCE_PENDING}" : detail
    end

    def certificate_results
      proxied_units.flat_map do |unit|
        next [] unless unit.proxy.ssl?

        unit.proxy.hosts.map do |domain|
          unit.proxy.custom_ssl_certificate? ? custom_certificate_check(unit.proxy, domain) : served_certificate_check(domain)
        end
      end
    end

    def dns_check(domain, unit_hosts, acme_issued: false)
      resolved = Resolv.getaddresses(domain)
      expected = expected_ips(unit_hosts)
      matching = resolved & expected

      if resolved.empty?
        result :dns, domain, :fail, with_issuance_note("does not resolve", acme_issued)
      elsif matching.any?
        result :dns, domain, :ok, "resolves to #{matching.join(", ")}"
      else
        result :dns, domain, :warn,
          with_issuance_note("resolves to #{resolved.join(", ")}, expected one of #{expected.join(", ")} (fine when fronted by a CDN or load balancer)", acme_issued)
      end
    rescue StandardError => e
      result :dns, domain, :fail, "could not resolve (#{e.message})"
    end

    def expected_ips(unit_hosts)
      unit_hosts.flat_map do |unit_host|
        if unit_host =~ Resolv::IPv4::Regex || unit_host =~ Resolv::IPv6::Regex
          [ unit_host ]
        else
          Resolv.getaddresses(unit_host)
        end
      end.uniq
    end

    def custom_certificate_check(proxy, domain)
      pem = proxy.certificate_pem_content
      return result(:certificate, domain, :fail, "the certificate_pem secret is missing or empty") if pem.blank?

      expiry_check domain, OpenSSL::X509::Certificate.new(pem), source: "configured certificate"
    rescue OpenSSL::X509::CertificateError => e
      result :certificate, domain, :fail, "certificate_pem is not a valid certificate (#{e.message})"
    rescue StandardError => e
      result :certificate, domain, :fail, "could not check the configured certificate (#{e.message})"
    end

    def served_certificate_check(domain)
      expiry_check domain, peer_certificate(domain), source: "served certificate"
    rescue StandardError => e
      result :certificate, domain, :warn, "could not check TLS on #{domain}:443 (#{e.message}) - expected if the app isn't deployed yet"
    end

    def expiry_check(domain, certificate, source:)
      days_left = ((certificate.not_after - Time.now) / SECONDS_PER_DAY).floor

      if days_left.negative?
        result :certificate, domain, :fail, "#{source} expired on #{certificate.not_after}"
      elsif days_left < CERTIFICATE_EXPIRY_WARN_DAYS
        result :certificate, domain, :warn, "#{source} expires in #{days_left} days (#{certificate.not_after})"
      else
        result :certificate, domain, :ok, "#{source} valid until #{certificate.not_after}"
      end
    end

    def peer_certificate(domain, port = 443)
      Socket.tcp(domain, port, connect_timeout: TLS_CONNECT_TIMEOUT) do |tcp|
        context = OpenSSL::SSL::SSLContext.new
        context.verify_mode = OpenSSL::SSL::VERIFY_NONE # only inspecting expiry, so self-signed is fine
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = domain

        begin
          ssl.connect
          ssl.peer_cert
        ensure
          ssl.close
        end
      end
    end
end
