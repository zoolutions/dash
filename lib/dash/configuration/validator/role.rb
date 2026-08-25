class Dash::Configuration::Validator::Role < Dash::Configuration::Validator
  def validate!
    validate_type! config, Array, Hash

    if config.is_a?(Array)
      validate_servers!(config)
    else
      super
      validate_labels!(config["labels"])
      validate_docker_options!(config["options"])
      validate_healthcheck_options!(config["healthcheck"], config["options"])
    end
  end

  private
    # `healthcheck: false` is the explicit opt-out from the readiness gate, so the
    # example's hash shape is not the only legal one.
    def validate_key_override!(key, value)
      return false unless key.to_s == "healthcheck"

      case value
      when false then true
      when Hash then false
      else error "should be a hash, or false to accept no readiness gate for this role"
      end
    end

    # Docker takes the last --health-* flag it sees, so overlapping sources would
    # silently pick a winner. Refuse the ambiguity instead.
    def validate_healthcheck_options!(healthcheck, options)
      return if healthcheck.blank?

      if health_option = options&.find { |key, _| key.to_s.start_with?("health-") }
        with_context("healthcheck") do
          error "cannot be combined with options/#{health_option.first}, remove one of them"
        end
      end
    end
end
