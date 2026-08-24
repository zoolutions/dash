class Kamal::Cli::Proxy::Drift
  attr_reader :host, :sshkit
  delegate :capture_with_info, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def container_exists?
    capture_with_info(*proxy.container_id, raise_on_non_zero_exit: false).strip.present?
  end

  # A proxy container has drifted when it was started with a different config
  # digest than the one the current configuration produces. Containers booted
  # by older dash versions carry no digest label and count as drifted, so
  # they converge on the first deploy after upgrading.
  def drifted?
    return @drifted if defined?(@drifted)
    @drifted = container_exists? && current_digest != expected_digest
  end

  def expected_digest
    @expected_digest ||= if proxy.proxy_run_config
      proxy.proxy_run_config.config_digest
    else
      Kamal::Configuration::Proxy::Run.digest(capture_with_info(*proxy.boot_config).strip)
    end
  end

  private
    def current_digest
      capture_with_info(*proxy.config_digest, raise_on_non_zero_exit: false).strip
    end

    def proxy
      @proxy ||= KAMAL.proxy(host)
    end
end
