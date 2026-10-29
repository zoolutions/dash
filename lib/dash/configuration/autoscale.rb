require "active_support/values/time_zone"

# The `autoscale:` block: which provider holds the pool members of scaled roles, how the
# controller (`dash autoscale run`) ticks, and where its signals and guards read from
# (`redis`, `postgres`, `prometheus`). Only the shape is checked here; credentials and URLs
# are secrets and are resolved on first use, like the registry password, so loading
# deploy.yml never needs them.
class Dash::Configuration::Autoscale
  include Dash::Configuration::Validation

  DEFAULT_INTERVAL = 10
  DEFAULT_LOCK_WAIT_TIMEOUT = 60
  DEFAULT_TIMEZONE = "UTC"

  # redis-client connects to the URL's host and verifies the certificate against that same
  # name, so through a tunnel (127.0.0.1) a TLS certificate can never verify.
  REDISS_VIA_MESSAGE = "rediss:// cannot be verified through via: redis-client checks the certificate against the address it " \
    "connects to, which a tunnel makes 127.0.0.1. Reach Redis directly, or use redis:// over the tunnel"

  def self.unverifiable_through_tunnel?(source, url)
    source.to_s == "redis" && url.is_a?(String) && url.downcase.start_with?("rediss://")
  end

  attr_reader :autoscale_config

  def initialize(config:)
    @autoscale_config = config.raw_config.autoscale
    @secrets = config.secrets
    validate! autoscale_config, with: Dash::Configuration::Validator::Autoscale unless autoscale_config.nil?
  end

  def configured?
    !autoscale_config.nil?
  end

  def provider_name
    provider_config&.keys&.first&.to_s
  end

  # The ops host that runs `dash autoscale run` and keeps its state, or nil to keep it on
  # the primary role's first baseline host (see Dash::Autoscale::StateStore.host).
  def controller
    autoscale_config&.fetch("controller", nil)
  end

  # Seconds between the controller's ticks.
  def interval
    autoscale_config&.fetch("interval", nil) || DEFAULT_INTERVAL
  end

  # Seconds a tick waits for the deploy lock before holding with `lock_busy`.
  def lock_wait_timeout
    autoscale_config&.fetch("lock_wait_timeout", nil) || DEFAULT_LOCK_WAIT_TIMEOUT
  end

  # The zone schedule crons are evaluated in.
  def timezone
    autoscale_config&.fetch("timezone", nil) || DEFAULT_TIMEZONE
  end

  def time_zone
    ActiveSupport::TimeZone[timezone]
  end

  def upcloud_username
    lookup(provider_config.dig("upcloud", "username"), "provider/upcloud/username")
  end

  def upcloud_password
    lookup(provider_config.dig("upcloud", "password"), "provider/upcloud/password")
  end

  def exec_script(action)
    provider_config.dig("exec", action.to_s)
  end

  # Whether `autoscale/<source>` (redis, postgres or prometheus) is set.
  def source?(source)
    !source_config(source).nil?
  end

  def source_url(source)
    lookup(source_config(source)["url"], "#{source}/url").tap do |url|
      if source_via(source) && self.class.unverifiable_through_tunnel?(source, url)
        raise Dash::ConfigurationError, "autoscale/#{source}: #{REDISS_VIA_MESSAGE}"
      end
    end
  end

  # The host to tunnel the source's connection through over SSH, or nil to connect directly.
  def source_via(source)
    source_config(source)&.fetch("via", nil)
  end

  def prometheus_token
    reference = source_config(:prometheus)&.fetch("token", nil)
    lookup(reference, "prometheus/token") unless reference.nil?
  end

  private
    attr_reader :secrets

    def provider_config
      autoscale_config&.fetch("provider", nil)
    end

    def source_config(source)
      autoscale_config&.fetch(source.to_s, nil)
    end

    # A one-element array names a secret; anything else is the value as written.
    def lookup(reference, path)
      value = reference.is_a?(Array) ? secrets[reference.first] : reference
      return value if value.present?

      if reference.is_a?(Array)
        raise Dash::ConfigurationError, "autoscale/#{path}: secret '#{reference.first}' resolved to an empty value — " \
          "if your secrets file forwards it from the environment (#{reference.first}=$#{reference.first}), export the variable before running dash"
      else
        raise Dash::ConfigurationError, "autoscale/#{path}: is blank"
      end
    end
end
