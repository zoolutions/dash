class Kamal::Configuration::Loadbalancer < Kamal::Configuration::Proxy
  CONTAINER_NAME = "load-balancer".freeze
  SHARED_CONTAINER_NAME = "kamal-proxy".freeze

  def self.validation_config_key
    "proxy"
  end

  def initialize(config:, proxy_config:, secrets:)
    super
  end

  def deploy_options
    opts = super

    # The parent strips host/tls/tls-domains when load balancing (the
    # app-level proxy no longer owns TLS) — the load balancer is where they
    # belong, so re-add.
    opts[:host] = hosts if hosts.present?
    opts[:tls] = true if ssl?
    opts.merge!(tls_domains_options)

    # Basic auth is an edge concern for the same reason: the parent strips it
    # when load balancing so only the load balancer challenges clients.
    opts[:"basic-auth"] = basic_auth_credential if basic_auth_credential.present?

    opts
  end

  # The load balancer fans a single service out to many targets, so unlike the
  # per-app proxy deploy (which takes one target) it takes the full list and
  # joins them into a single --target flag, honouring app_port for each.
  def deploy_command_args(targets:)
    target_arg = targets.map { |target| "#{target}:#{app_port}" }.join(",")
    optionize ({ target: target_arg }).merge(deploy_options), with: "="
  end

  def directory
    File.join config.run_directory, "loadbalancer"
  end

  def container_name
    on_proxy_host? ? SHARED_CONTAINER_NAME : CONTAINER_NAME
  end

  # When loadbalancer is on a proxy host, it takes over the proxy role
  def on_proxy_host?
    config.proxy_hosts.include?(config.proxy.effective_loadbalancer)
  end
end
