class Dash::Configuration::Boot
  include Dash::Configuration::Validation

  attr_reader :boot_config

  # Pass boot_config/context to scope this to a single role: the role's own `boot:` hash,
  # and a context that points at the role in validation errors.
  def initialize(config:, boot_config: nil, context: nil)
    @boot_config = boot_config || config.raw_config.boot || {}
    validate! @boot_config, context: context
    validate_canary!(context || self.class.validation_config_key)
  end

  # The group size to slice `hosts` by. A percentage only means something against the set
  # it will actually be applied to, and that set is not known until run time — `--roles`
  # and `--hosts` narrow it, and accessories are never booted at all. So callers pass the
  # hosts they are about to group rather than Boot reaching for a host list of its own.
  def limit_for(hosts)
    limit = boot_config["limit"]

    if limit.to_s.end_with?("%")
      [ hosts.count * limit.to_i / 100, 1 ].max
    else
      limit
    end
  end

  # Whether a limit is configured at all. Deliberately not a reader for the raw value:
  # a percentage means nothing without the hosts it slices, so anything that needs the
  # group size has to go through limit_for.
  def limit?
    boot_config["limit"].present?
  end

  def wait
    boot_config["wait"]
  end

  # How many primary-role hosts boot alone, one at a time, before the rest boot together.
  # Whole-deploy only — Cli::App#host_boot_groups is the sole consumer.
  def canary
    boot_config["canary"]
  end

  def canary?
    canary.present?
  end

  # Whether this config splits hosts into more than one group at all — what `wait` needs
  # in order to mean anything.
  def groups?
    limit? || canary?
  end

  def parallel_roles
    boot_config["parallel_roles"]
  end

  # SSHKit runner options expressing this pacing over `hosts`. Without a limit there is
  # nothing to pace and `on` keeps its default parallel runner.
  #
  # `wait` is always explicit: SSHKit::Runner::Sequential and ::Group both fall back to a
  # 2 second interval, where Kamal's own boot wait means "no sleep unless you asked for
  # one". A limit of 1 goes through Sequential rather than Group, which runs one host per
  # slice without spawning a thread to do it. Neither trails a wait past the last group —
  # Sequential pops its final host, and Kamal patches Group to match (sshkit_with_ext.rb).
  def runner_options_for(hosts)
    limit = limit_for(hosts)
    return {} unless limit

    if limit == 1
      { in: :sequence, wait: wait.to_i }
    else
      { in: :groups, limit: limit, wait: wait.to_i }
    end
  end

  private
    # The example-driven validator has already checked the type; the range and the
    # top-level-only rule are ours. A role-scoped Boot always carries a context.
    def validate_canary!(context)
      return unless canary?

      if context != self.class.validation_config_key
        raise Dash::ConfigurationError, "#{context}/canary is only supported at the top-level boot: " \
          "it slices the primary role's hosts ahead of every other role"
      end

      if canary < 1
        raise Dash::ConfigurationError, "#{context}/canary must be at least 1, got #{canary}"
      end
    end
end
