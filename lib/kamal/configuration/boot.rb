class Kamal::Configuration::Boot
  include Kamal::Configuration::Validation

  attr_reader :boot_config

  # Pass boot_config/context to scope this to a single role: the role's own `boot:` hash,
  # and a context that points at the role in validation errors.
  def initialize(config:, boot_config: nil, context: nil)
    @boot_config = boot_config || config.raw_config.boot || {}
    validate! @boot_config, context: context
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

  def wait
    boot_config["wait"]
  end

  def parallel_roles
    boot_config["parallel_roles"]
  end

  # SSHKit runner options expressing this pacing over `hosts`. Without a limit there is
  # nothing to pace and `on` keeps its default parallel runner.
  #
  # `wait` is always explicit: SSHKit::Runner::Sequential and ::Group both fall back to a
  # 2 second interval, where Kamal's own boot wait means "no sleep unless you asked for
  # one". A limit of 1 goes through Sequential rather than Group, because Group also
  # sleeps after the final host.
  def runner_options_for(hosts)
    limit = limit_for(hosts)
    return {} unless limit

    if limit == 1
      { in: :sequence, wait: wait.to_i }
    else
      { in: :groups, limit: limit, wait: wait.to_i }
    end
  end
end
