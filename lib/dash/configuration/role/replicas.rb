# How many containers of one role run on each of its hosts. The bounds come from
# deploy.yml; the count in between is never stored - it is whatever is running, which
# `dash scale set` changes and a deploy reads back (see Dash::Cli::App::Boot).
class Dash::Configuration::Role::Replicas
  # Docker options every replica on a host would claim for itself.
  EXCLUSIVE_OPTIONS = %w[ publish p name hostname ]
  VOLUME_OPTIONS = %w[ volume v mount volumes-from ]

  attr_reader :min, :max, :context

  def initialize(replicas_config:, context:)
    @context = context

    case replicas_config
    when nil then @min = @max = 1
    when Integer then @min = @max = replicas_config
    else
      @min = replicas_config.fetch("min", 1)
      @max = replicas_config.fetch("max", [ @min, 1 ].max)
    end

    validate!
  end

  def scalable?
    max > 1
  end

  def numbers
    (1..max).to_a
  end

  # A deploy boots the running count, kept within the bounds: a crash cannot shrink the
  # role below min, and a lowered max takes effect.
  def clamp(running)
    running.clamp(min, max)
  end

  def to_s
    min == max ? "× #{max} #{"replica".pluralize(max)}" : "× #{min}–#{max} replicas"
  end

  # Checks that need the rest of the role (its docker options, its proxy), which is only
  # complete once Dash::Configuration has finished building - see
  # Dash::Configuration#ensure_replicas_fit_their_roles.
  def ensure_fits!(role, volumes:)
    return unless scalable?

    if (option = role.docker_option_keys.find { |key| EXCLUSIVE_OPTIONS.include?(key) })
      error "max > 1 cannot be combined with options/#{option}, every replica on a host would claim it"
    end

    if role.running_proxy? && role.proxy.proxy_config.dig("sleep", "after").present?
      error "max > 1 cannot be combined with proxy/sleep until dash-proxy is proven to sleep and wake every replica together"
    end

    shared = volumes + role.docker_option_values(*VOLUME_OPTIONS)
    shared.each do |volume|
      warn "#{context}: every replica on a host shares the volume #{volume} - fine for read-only config or a shared cache, wrong for a per-process store"
    end
  end

  private
    def validate!
      error "min must be at least 1" unless min >= 1
      error "min (#{min}) cannot be greater than max (#{max})" if min > max
    end

    def error(message)
      raise Dash::ConfigurationError, "#{context}: #{message}"
    end
end
