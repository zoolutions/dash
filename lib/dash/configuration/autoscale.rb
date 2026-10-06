require "active_support/values/time_zone"

# The `autoscale:` block: which provider holds the pool members of scaled roles, and how
# the controller (`dash autoscale run`) ticks. Only the shape is checked here; credentials
# are secrets and are resolved on the first API call, like the registry password, so
# loading deploy.yml never needs them.
class Dash::Configuration::Autoscale
  include Dash::Configuration::Validation

  DEFAULT_INTERVAL = 10
  DEFAULT_LOCK_WAIT_TIMEOUT = 60
  DEFAULT_TIMEZONE = "UTC"

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
    lookup("username")
  end

  def upcloud_password
    lookup("password")
  end

  def exec_script(action)
    provider_config.dig("exec", action.to_s)
  end

  private
    attr_reader :secrets

    def provider_config
      autoscale_config&.fetch("provider", nil)
    end

    def lookup(key)
      reference = provider_config.dig("upcloud", key)
      value = reference.is_a?(Array) ? secrets[reference.first] : reference
      return value if value.present?

      if reference.is_a?(Array)
        raise Dash::ConfigurationError, "autoscale/provider/upcloud/#{key}: secret '#{reference.first}' resolved to an empty value — " \
          "if your secrets file forwards it from the environment (#{reference.first}=$#{reference.first}), export the variable before running dash"
      else
        raise Dash::ConfigurationError, "autoscale/provider/upcloud/#{key}: is blank"
      end
    end
end
