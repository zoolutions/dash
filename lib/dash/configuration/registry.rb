class Dash::Configuration::Registry
  include Dash::Configuration::Validation

  def initialize(config:, secrets:, context: "registry")
    @registry_config = config["registry"] || {}
    @secrets = secrets
    @context = context
    validate! registry_config, context: context, with: Dash::Configuration::Validator::Registry
  end

  def server
    registry_config["server"]
  end

  def username
    lookup("username")
  end

  def password
    lookup("password")
  end

  def local?
    server.to_s.match?("^localhost[:$]")
  end

  def local_port
    local? ? (server.split(":").last.to_i || 80) : nil
  end

  private
    attr_reader :registry_config, :secrets, :context

    # A blank credential would reach the remote host as an empty `docker login -p`,
    # where docker falls back to prompting and dies with the opaque "Cannot perform
    # an interactive login from a non TTY device" — fail locally instead.
    def lookup(key)
      value =
        if registry_config[key].is_a?(Array)
          secrets[registry_config[key].first]
        else
          registry_config[key]
        end

      validate_present! key, value unless local?
      value
    end

    def validate_present!(key, value)
      return if value.present?

      if registry_config[key].is_a?(Array)
        secret = registry_config[key].first
        raise Dash::ConfigurationError,
          "#{context}/#{key}: secret '#{secret}' resolved to an empty value — " \
          "if your secrets file forwards it from the environment (#{secret}=$#{secret}), export the variable before running dash"
      else
        raise Dash::ConfigurationError, "#{context}/#{key}: is blank"
      end
    end
end
