class Dash::Configuration::Validator::Autoscale < Dash::Configuration::Validator
  PROVIDERS = %w[ upcloud exec ]
  CREDENTIALS = %w[ username password ]
  REQUIRED_SCRIPTS = %w[ members start stop ]

  # Root keys of the autoscaling controller (zoolutions/dash#180, phases 2-3).
  CONTROLLER_KEYS = %w[ interval redis postgres prometheus ]

  def validate!
    validate_type! config, Hash
    validate_no_controller_keys!
    check_unknown_keys! config, example

    with_context("provider") do
      provider = config["provider"]
      error "is required" if provider.nil?
      validate_type! provider, Hash
      check_unknown_keys! provider, example["provider"]
      error "set exactly one of #{PROVIDERS.join(" or ")}" unless provider.size == 1

      validate_upcloud!(provider["upcloud"]) if provider.key?("upcloud")
      validate_exec!(provider["exec"]) if provider.key?("exec")
    end
  end

  private
    def validate_no_controller_keys!
      if (key = (config.keys.map(&:to_s) & CONTROLLER_KEYS).first)
        error "#{key} belongs to the autoscaling controller, which is not part of dash yet (zoolutions/dash#180)"
      end
    end

    def validate_upcloud!(upcloud)
      with_context("upcloud") do
        validate_type! upcloud, Hash
        check_unknown_keys! upcloud, example.dig("provider", "upcloud")

        CREDENTIALS.each do |key|
          with_context(key) do
            value = upcloud[key]
            error "is required" if value.blank?

            unless value.is_a?(String) || (value.is_a?(Array) && value.size == 1 && value.first.is_a?(String))
              error "should be a string or an array with one string (for secret lookup)"
            end
          end
        end
      end
    end

    def validate_exec!(exec)
      with_context("exec") do
        validate_type! exec, Hash
        check_unknown_keys! exec, example.dig("provider", "exec")

        exec.each { |key, value| with_context(key) { validate_type! value, String } }
        REQUIRED_SCRIPTS.each { |key| with_context(key) { error "is required" if exec[key].blank? } }
      end
    end
end
