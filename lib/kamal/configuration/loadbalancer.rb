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
    opts.merge!(tls_options)

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

  # Publish/logging/docker options for the load balancer container. When the
  # deploy YAML sets proxy.run, honour it (publish: false, custom ports,
  # options); otherwise fall back to publishing the default 80/443.
  def run_args
    if run
      [ *run.publish_args, *run.logging_args, *run.options_args ]
    else
      [ "--publish", "80:80", "--publish", "443:443" ]
    end
  end

  # Digest of the argv the load balancer container is booted with, so a second
  # app pointing at the same host can tell whether its proxy/run agrees with
  # whatever is already running there.
  def run_config_digest
    Kamal::Configuration::Proxy::Run.digest(*run_args)
  end

  # Kamal has no app identifier, so ownership of a service on a shared load
  # balancer is expressed as repository plus destination-qualified service name:
  # the repository separates two different apps, the destination separates two
  # deployments of one app. The load balancer registers services under the bare
  # service name, so both can collide.
  def owner_token
    [ config.service_and_destination, config.repository ].join(" ")
  end

  def run_config_record
    [ owner_token, run_config_digest ].join(" ")
  end

  def run_config_file
    File.join directory, "run_config"
  end

  def services_directory
    File.join directory, "services"
  end

  def service_owner_file
    File.join services_directory, config.service
  end

  def container_name
    on_proxy_host? ? SHARED_CONTAINER_NAME : CONTAINER_NAME
  end

  # When loadbalancer is on a proxy host, it takes over the proxy role
  def on_proxy_host?
    config.proxy_hosts.include?(config.proxy.effective_loadbalancer)
  end
end
