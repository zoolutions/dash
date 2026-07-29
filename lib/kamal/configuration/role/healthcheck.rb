class Kamal::Configuration::Role::Healthcheck
  DEFAULT_PATH = "/up"
  DEFAULT_INTERVAL = 1

  attr_reader :healthcheck_config, :context
  delegate :optionize, to: Kamal::Utils

  def initialize(healthcheck_config:, context: "healthcheck")
    @healthcheck_config = healthcheck_config
    @context = context
    validate!
  end

  # The command docker runs inside the container. Custom commands win; otherwise
  # we build the same curl check Kamal 1 shipped.
  def cmd
    healthcheck_config["cmd"] || http_health_check
  end

  def port
    healthcheck_config["port"]
  end

  def path
    healthcheck_config.fetch("path", DEFAULT_PATH)
  end

  def interval
    healthcheck_config.fetch("interval", DEFAULT_INTERVAL)
  end

  def args
    optionize({
        "health-cmd" => cmd,
        "health-interval" => duration(interval),
        "health-timeout" => duration(healthcheck_config["timeout"]),
        "health-retries" => healthcheck_config["retries"],
        "health-start-period" => duration(healthcheck_config["start_period"]),
        "health-start-interval" => duration(healthcheck_config["start_interval"])
      }.compact)
  end

  private
    def http_health_check
      "curl -f #{URI.join("http://localhost:#{port}", path)} || exit 1"
    end

    # Bare numbers are seconds, anything else is passed to docker as written.
    def duration(value)
      case value
      when nil then nil
      when /\A\d+\z/, Integer then "#{value}s"
      else value.to_s
      end
    end

    def validate!
      if healthcheck_config["cmd"].blank? && port.blank?
        error "port is required unless cmd is set"
      end

      # Utils#escape_shell_value leaves ${...} alone, so it would expand in the
      # deploy host's shell when docker run is assembled.
      if healthcheck_config["cmd"].to_s.include?("${")
        error "cannot contain ${...}, it would expand on the deploy host, not in the container", context: "cmd"
      end
    end

    def error(message, context: nil)
      raise Kamal::ConfigurationError, "#{[ @context, context ].compact.join("/")}: #{message}"
    end
end
