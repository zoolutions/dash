class Dash::Configuration::Role::Healthcheck
  DEFAULT_PATH = "/up"
  DEFAULT_INTERVAL = 1

  # Everything that only ever reaches docker as a `--health-*` flag. An exec probe emits
  # none of those, so combining them would silently drop whatever the operator wrote.
  DOCKER_ONLY_KEYS = %w[ cmd port path interval timeout retries start_period start_interval ]

  attr_reader :healthcheck_config, :context
  delegate :optionize, to: Dash::Utils

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

  # The probe kamal `docker exec`s from the deploy host during a boot, for images whose
  # HEALTHCHECK cannot be changed. Deploy-time only: docker never runs it, so `docker ps`
  # shows no `(healthy)` and `docker inspect` keeps no probe history.
  def exec
    healthcheck_config["exec"]
  end

  def exec?
    exec.present?
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
    return [] if exec?

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
      if exec? && (conflicting = DOCKER_ONLY_KEYS.find { |key| healthcheck_config[key].present? })
        error "cannot be combined with #{conflicting}, which only configures docker's own healthcheck " \
          "— an exec probe is polled from the deploy host", context: "exec"
      end

      if healthcheck_config["cmd"].blank? && !exec? && port.blank?
        error "port is required unless cmd or exec is set"
      end

      # Utils#escape_shell_value leaves ${...} alone, so it would expand in the
      # deploy host's shell when docker run is assembled. `exec` has no such problem:
      # Commands::App#health_probe single-quotes it, so it expands in the container.
      if healthcheck_config["cmd"].to_s.include?("${")
        error "cannot contain ${...}, it would expand on the deploy host, not in the container", context: "cmd"
      end
    end

    def error(message, context: nil)
      raise Dash::ConfigurationError, "#{[ @context, context ].compact.join("/")}: #{message}"
    end
end
