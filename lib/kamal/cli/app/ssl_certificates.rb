class Kamal::Cli::App::SslCertificates
  attr_reader :host, :role, :sshkit
  delegate :execute, :info, :upload!, to: :sshkit

  def initialize(host, role, sshkit)
    @host = host
    @role = role
    @sshkit = sshkit
  end

  def run
    return unless role.running_proxy? && (role.proxy.custom_ssl_certificate? || role.proxy.client_ca?)

    info "Writing SSL certificates for #{role.name} on #{host}"
    execute *app.create_ssl_directory

    if role.proxy.custom_ssl_certificate?
      if cert_content = role.proxy.certificate_pem_content
        upload!(StringIO.new(cert_content), role.proxy.host_tls_cert, mode: "0644")
      end
      if key_content = role.proxy.private_key_pem_content
        upload!(StringIO.new(key_content), role.proxy.host_tls_key, mode: "0644")
      end
    end

    # The server certificate arrives as secret content; the client CA is a public
    # trust anchor named by a local path, so it is uploaded straight from disk.
    if role.proxy.client_ca?
      upload!(role.proxy.client_ca_path, role.proxy.host_client_ca, mode: "0644")
    end
  end

  private
    def app
      @app ||= KAMAL.app(role: role, host: host)
    end
end
