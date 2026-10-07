# How many HOSTS a role may run on: the baseline listed under `hosts`, plus pool members the
# autoscale provider holds (see Dash::Autoscale::Pool). `min` and `max` count hosts, the
# baseline included; `replicas` counts containers per host - the two never mix.
#
# The controller's keys (`schedule`, `warmup`, `cooldown`, `step`) count containers, the
# unit of `dash scale set`; see Dash::Autoscale::Policy.
class Dash::Configuration::Role::Scale
  MEMBERS = %w[ power create ]
  ADDRESSES = %w[ private public utility ]
  WINDOW_KEYS = %w[ cron for min ]
  DEFAULT_BOOT_TIMEOUT = 300
  DEFAULT_COOLDOWN_UP = 60
  DEFAULT_COOLDOWN_DOWN = 600
  MAX_WINDOW = 7 * 86_400

  attr_reader :min, :max, :template, :address, :boot_timeout, :schedule, :warmup, :cooldown_up, :cooldown_down, :step, :replicas, :context

  def initialize(scale_config:, baseline:, replicas:, context:)
    @context = context
    @replicas = replicas
    @min = scale_config.fetch("min", baseline)
    @max = scale_config["max"]
    @members = scale_config.fetch("members", "power").to_s
    @template = scale_config["template"]
    @address = scale_config.fetch("address", "private").to_s
    @boot_timeout = scale_config.fetch("boot_timeout", DEFAULT_BOOT_TIMEOUT)
    @warmup = scale_config.fetch("warmup", boot_timeout)
    @cooldown_up = scale_config.dig("cooldown", "up") || DEFAULT_COOLDOWN_UP
    @cooldown_down = scale_config.dig("cooldown", "down") || DEFAULT_COOLDOWN_DOWN
    @step = scale_config.fetch("step", replicas.max)

    validate!(baseline)
    @schedule = Array(scale_config["schedule"]).each_with_index.map { |window, index| parse_window(window, index) }
  end

  def members
    @members.to_sym
  end

  def power?
    members == :power
  end

  def create?
    members == :create
  end

  # The role's bounds in containers: every host it must keep at replicas min, every host
  # it may have at replicas max.
  def min_count
    min * replicas.min
  end

  def max_count
    max * replicas.max
  end

  # Whether `dash scale set` can place `count` containers: on as few hosts as hold them,
  # never fewer than scale min, each within the replicas bounds (Dash::Cli::Scale::HostPlan).
  def splittable?(count)
    hosts = [ (count.to_f / replicas.max).ceil, min ].max
    hosts <= max && hosts * replicas.min <= count
  end

  private
    def validate!(baseline)
      error "max", "is required" if max.nil?
      error "members", "must be #{MEMBERS.join(" or ")}, not #{@members}" unless MEMBERS.include?(@members)
      error "address", "must be #{ADDRESSES.to_sentence(two_words_connector: " or ", last_word_connector: " or ")}, not #{address}" unless ADDRESSES.include?(address)
      error nil, "min (#{min}) cannot be less than the #{baseline} hosts listed under hosts" if min < baseline
      error nil, "min (#{min}) cannot be greater than max (#{max})" if min > max
      error "boot_timeout", "must be at least 1 second" unless boot_timeout.positive?
      error "warmup", "must be at least 0" if warmup.negative?
      error "cooldown/up", "must be at least 0" if cooldown_up.negative?
      error "cooldown/down", "must be at least 0" if cooldown_down.negative?
      error "step", "must be at least 1" unless step.positive?
      validate_template!
    end

    def validate_template!
      if create?
        error "template", "is required with members: create" if template.blank?
        error "template/network", "is required when address is private" if address == "private" && template["network"].blank?
      elsif template.present?
        error "template", "is only used with members: create"
      end
    end

    def parse_window(window, index)
      key = "schedule/#{index}"
      if (unknown = (window.keys.map(&:to_s) - WINDOW_KEYS).first)
        error key, "unknown key: #{unknown}"
      end
      WINDOW_KEYS.each { |required| error "#{key}/#{required}", "is required" if window[required].nil? }

      Window.new(cron: window_cron(window["cron"], key), duration: window_duration(window["for"], key), min: window_min(window["min"], key))
    end

    def window_cron(cron, key)
      Dash::Autoscale::Cron.parse(cron)
    rescue Dash::Autoscale::Cron::Error => e
      error "#{key}/cron", e.message
    end

    def window_duration(value, key)
      duration = begin
        Dash::Autoscale::Duration.parse(value)
      rescue ArgumentError => e
        error "#{key}/for", e.message
      end

      error "#{key}/for", "must be 1 second to 7 days, not #{value}" unless duration.between?(1, MAX_WINDOW)
      duration
    end

    # Below min_count a window changes nothing, so only a min above it must be one
    # `dash scale set` can place.
    def window_min(value, key)
      unless value.is_a?(Integer) && value.between?(1, max_count)
        error "#{key}/min", "must be 1 to #{max_count} (scale max #{max} × replicas max #{replicas.max}), not #{value}"
      end

      if value > min_count && !splittable?(value)
        error "#{key}/min", "#{value} containers cannot be split over the role's hosts " \
          "(replicas min #{replicas.min}, max #{replicas.max} per host, #{min} to #{max} hosts)"
      end

      value
    end

    def error(key, message)
      raise Dash::ConfigurationError, "#{[ context, key ].compact.join("/")}: #{message}"
    end
end
