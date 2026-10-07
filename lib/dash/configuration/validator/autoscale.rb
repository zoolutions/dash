class Dash::Configuration::Validator::Autoscale < Dash::Configuration::Validator
  PROVIDERS = %w[ upcloud exec ]
  CREDENTIALS = %w[ username password ]
  SCRIPTS = %w[ members start stop create destroy ]
  REQUIRED_SCRIPTS = %w[ members start stop ]

  # Root keys of the reactive autoscaling rules (zoolutions/dash#180, phase 3).
  CONTROLLER_KEYS = %w[ redis postgres prometheus ]
  MINIMUM_INTERVAL = 5

  def validate!
    validate_type! config, Hash
    validate_no_controller_keys!
    check_unknown_keys! config, example
    validate_controller!

    with_context("provider") do
      provider = config["provider"]
      error "is required" if provider.nil?
      validate_type! provider, Hash
      # Against the constants, not the example: the docs show each provider on its own.
      check_unknown_keys! provider, PROVIDERS.index_with(nil)
      error "set exactly one of #{PROVIDERS.join(" or ")}" unless provider.size == 1

      validate_upcloud!(provider["upcloud"]) if provider.key?("upcloud")
      validate_exec!(provider["exec"]) if provider.key?("exec")
    end
  end

  private
    def validate_no_controller_keys!
      if (key = (config.keys.map(&:to_s) & CONTROLLER_KEYS).first)
        error "#{key} belongs to the reactive autoscaling rules, which are not part of dash yet (zoolutions/dash#180, Phase 3)"
      end
    end

    def validate_controller!
      with_context("controller") do
        host = config["controller"]
        error "should be a host name" unless host.nil? || (host.is_a?(String) && host.strip.present?)
      end
      with_context("interval") { validate_at_least! config["interval"], MINIMUM_INTERVAL, " seconds" }
      with_context("lock_wait_timeout") { validate_at_least! config["lock_wait_timeout"], 0 }

      with_context("timezone") do
        timezone = config["timezone"]
        next if timezone.nil?

        error "should be a string" unless timezone.is_a?(String)
        error "unknown time zone #{timezone}, use an IANA name such as Europe/Stockholm" if ActiveSupport::TimeZone[timezone].nil?
      end
    end

    def validate_at_least!(value, minimum, unit = nil)
      return if value.nil?

      error "should be an integer" unless value.is_a?(Integer)
      error "must be at least #{minimum}#{unit}, not #{value}" if value < minimum
    end

    def validate_upcloud!(upcloud)
      with_context("upcloud") do
        validate_type! upcloud, Hash
        check_unknown_keys! upcloud, CREDENTIALS.index_with(nil)

        CREDENTIALS.each do |key|
          with_context(key) do
            value = upcloud[key]
            error "is required" if value.blank? || (value.is_a?(Array) && value.first.blank?)

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
        check_unknown_keys! exec, SCRIPTS.index_with(nil)

        exec.each { |key, value| with_context(key) { validate_type! value, String } }
        REQUIRED_SCRIPTS.each { |key| with_context(key) { error "is required" if exec[key].blank? } }
      end
    end
end
