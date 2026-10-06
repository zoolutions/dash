# How many HOSTS a role may run on: the baseline listed under `hosts`, plus pool members the
# autoscale provider holds (see Dash::Autoscale::Pool). `min` and `max` count hosts, the
# baseline included; `replicas` counts containers per host - the two never mix.
class Dash::Configuration::Role::Scale
  MEMBERS = %w[ power create ]
  ADDRESSES = %w[ private public utility ]
  DEFAULT_BOOT_TIMEOUT = 300

  attr_reader :min, :max, :template, :address, :boot_timeout, :context

  def initialize(scale_config:, baseline:, context:)
    @context = context
    @min = scale_config.fetch("min", baseline)
    @max = scale_config["max"]
    @members = scale_config.fetch("members", "power").to_s
    @template = scale_config["template"]
    @address = scale_config.fetch("address", "private").to_s
    @boot_timeout = scale_config.fetch("boot_timeout", DEFAULT_BOOT_TIMEOUT)

    validate!(baseline)
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

  private
    def validate!(baseline)
      error "max", "is required" if max.nil?
      error "members", "must be #{MEMBERS.join(" or ")}, not #{@members}" unless MEMBERS.include?(@members)
      error "address", "must be #{ADDRESSES.to_sentence(two_words_connector: " or ", last_word_connector: " or ")}, not #{address}" unless ADDRESSES.include?(address)
      error nil, "min (#{min}) cannot be less than the #{baseline} hosts listed under hosts" if min < baseline
      error nil, "min (#{min}) cannot be greater than max (#{max})" if min > max
      error "boot_timeout", "must be at least 1 second" unless boot_timeout.positive?
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

    def error(key, message)
      raise Dash::ConfigurationError, "#{[ context, key ].compact.join("/")}: #{message}"
    end
end
