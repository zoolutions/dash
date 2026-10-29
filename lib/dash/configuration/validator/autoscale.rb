class Dash::Configuration::Validator::Autoscale < Dash::Configuration::Validator
  PROVIDERS = %w[ upcloud exec ]
  CREDENTIALS = %w[ username password ]
  SCRIPTS = %w[ members start stop create destroy ]
  REQUIRED_SCRIPTS = %w[ members start stop ]

  MINIMUM_INTERVAL = 5

  # What a signal or guard reads through, and the URL schemes each one takes.
  SOURCES = {
    "redis" => %w[ redis rediss ],
    "postgres" => %w[ postgres postgresql ],
    "prometheus" => %w[ http https ]
  }.freeze

  def validate!
    validate_type! config, Hash
    check_unknown_keys! config, example
    validate_controller!
    SOURCES.each_key { |source| validate_source!(source, config[source]) if config.key?(source) }

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
    def validate_controller!
      with_context("controller") do
        host = config["controller"]
        error "should be a host name" unless host.nil? || (host.is_a?(String) && host.present? && host == host.strip)
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

    def validate_source!(source, block)
      with_context(source) do
        validate_type! block, Hash
        check_unknown_keys! block, (source == "prometheus" ? %w[ url via token ] : %w[ url via ]).index_with(nil)

        with_context("url") do
          validate_secret_or_string! block["url"]
          url = block["url"]
          if url.is_a?(String)
            error "should start with #{SOURCES[source].map { |scheme| "#{scheme}://" }.join(" or ")}" if SOURCES[source].none? { |scheme| url.start_with?("#{scheme}://") }
            valid_uri!(url)
          end
        end

        with_context("via") do
          via = block["via"]
          error "should be a host name" unless via.nil? || (via.is_a?(String) && via.present? && via == via.strip)
        end

        with_context("token") { validate_secret_or_string! block["token"] } if block.key?("token")

        # Both checked again for a secret URL: rediss when it is resolved
        # (Dash::Configuration::Autoscale#source_url), the host when the tunnel opens.
        if block["via"] && Dash::Configuration::Autoscale.unverifiable_through_tunnel?(source, block["url"])
          error Dash::Configuration::Autoscale::REDISS_VIA_MESSAGE
        end
        error "via needs a URL that names its host" if block["via"] && block["url"].is_a?(String) && URI(block["url"]).host.blank?
      end
    end

    def valid_uri!(url)
      URI(url)
    rescue URI::InvalidURIError
      error "is not a valid URL"
    end

    def validate_secret_or_string!(value)
      error "is required" if value.blank? || (value.is_a?(Array) && value.first.blank?)

      unless value.is_a?(String) || (value.is_a?(Array) && value.size == 1 && value.first.is_a?(String))
        error "should be a string or an array with one string (for secret lookup)"
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
          with_context(key) { validate_secret_or_string! upcloud[key] }
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
