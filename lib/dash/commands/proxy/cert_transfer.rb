# Certificate store transfer, shared by the proxy and loadbalancer command
# builders (dash proxy export_certs / import_certs).
#
# Archives leave through the apps-config bind mount — the one container path
# that is also a host path — and arrive through stdin into a one-off container:
# a bind-mounted source would need host permissions the container user cannot
# be guaranteed to have, and the store must be written as the image's own user
# or the proxy cannot read it afterwards.
#
# The including class provides `container_name`, `cert_store_volume_args` (the
# config volume mount) and `one_off_image` (the image tokens for a one-off
# container).
module Dash::Commands::Proxy::CertTransfer
  CERT_ARCHIVE_FILENAME = "certs-export.tar.gz"
  CERT_IMPORT_STAGING_FILENAME = "certs-import"
  CONTAINER_IMPORT_PATH = "/tmp/kamal-cert-import"

  # Through the RPC socket of the running container, under the proxy's own
  # certificate write lock, so a backup taken mid-renewal is never torn.
  def export_certs
    docker :exec, container_name, "kamal-proxy", :export, :certs, certs_archive_container_path
  end

  # Reads the data directory offline over the config volume — only safe when
  # the container is stopped, which Dash::Cli::Proxy guarantees.
  def export_certs_offline
    docker :run, "--rm",
      *cert_store_volume_args,
      *config.proxy_boot.apps_volume.docker_args,
      *one_off_image,
      "kamal-proxy", :export, :certs, certs_archive_container_path
  end

  # Offline by design (kamal-proxy import has no RPC path): the one-off
  # container mounts the config volume — creating it when no proxy has booted
  # yet, which is the Traefik-migration case — and the staged source streams
  # through stdin.
  def import_certs(traefik_acme: false, resolver: nil, force: false, verify: false)
    source_flag = traefik_acme ? "traefik-acme" : "archive"
    # Base#shell single-quotes the payload and escapes embedded apostrophes -
    # without that, an apostrophe in a resolver name would end the quoting and
    # run whatever follows on the target host.
    import_command = shell [
      "cat > #{CONTAINER_IMPORT_PATH} &&",
      "kamal-proxy import certs",
      *optionize({ source_flag => CONTAINER_IMPORT_PATH, resolver: resolver, force: force || nil, verify: verify || nil }.compact, with: "=")
    ]

    [
      *docker(:run, "--rm", "--interactive", *cert_store_volume_args, *one_off_image, *import_command),
      "<", certs_import_host_path
    ]
  end

  def certs_archive_host_path
    File.join config.proxy_boot.apps_directory, CERT_ARCHIVE_FILENAME
  end

  def certs_archive_container_path
    File.join config.proxy_boot.apps_container_directory, CERT_ARCHIVE_FILENAME
  end

  def certs_import_host_path
    File.join config.proxy_boot.host_directory, CERT_IMPORT_STAGING_FILENAME
  end

  def remove_certs_archive
    remove_file certs_archive_host_path
  end

  def remove_certs_import
    remove_file certs_import_host_path
  end
end
