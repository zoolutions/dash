class Dash::Configuration::Validator::Role < Dash::Configuration::Validator
  # Keys of the reactive autoscaling rules (zoolutions/dash#180, phase 3). Named so that a
  # half-configured rule fails with a reason, not a generic unknown-key error.
  CONTROLLER_KEYS = %w[ signal up down hold_when ]

  def validate!
    validate_type! config, Array, Hash

    if config.is_a?(Array)
      validate_servers!(config)
    else
      validate_no_controller_keys!(config["scale"])
      super
      validate_labels!(config["labels"])
      validate_docker_options!(config["options"])
      validate_healthcheck_options!(config["healthcheck"], config["options"])
    end
  end

  private
    def validate_no_controller_keys!(scale)
      return unless scale.is_a?(Hash)

      if (key = (scale.keys.map(&:to_s) & CONTROLLER_KEYS).first)
        with_context("scale") do
          error "#{key} belongs to the reactive autoscaling rules, which are not part of dash yet (zoolutions/dash#180, Phase 3)"
        end
      end
    end

    # `healthcheck: false` is the explicit opt-out from the readiness gate, so the
    # example's hash shape is not the only legal one.
    def validate_key_override!(key, value)
      case key.to_s
      when "healthcheck"
        case value
        when false then true
        when Hash then false
        else error "should be a hash, or false to accept no readiness gate for this role"
        end
      when "replicas"
        # `replicas: 2` is shorthand for min and max, so the example's hash shape is not
        # the only legal one either.
        case value
        when Integer then true
        when Hash then false
        else error "should be an integer, or a hash with min and max"
        end
      else
        false
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
