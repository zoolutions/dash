class Kamal::Configuration::Boot
  include Kamal::Configuration::Validation

  attr_reader :boot_config, :host_count

  # Pass boot_config/host_count/context to scope this to a single role: the role's own
  # `boot:` hash, its own host count (so a percentage limit means a percentage of that
  # role), and a context that points at the role in validation errors.
  def initialize(config:, boot_config: nil, host_count: nil, context: nil)
    @boot_config = boot_config || config.raw_config.boot || {}
    @host_count = host_count || config.all_hosts.count
    validate! @boot_config, context: context
  end

  def limit
    limit = boot_config["limit"]

    if limit.to_s.end_with?("%")
      [ host_count * limit.to_i / 100, 1 ].max
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

  # SSHKit runner options expressing this pacing over one set of hosts. Without a limit
  # there is nothing to pace and `on` keeps its default parallel runner.
  #
  # `wait` is always explicit: SSHKit::Runner::Sequential and ::Group both fall back to a
  # 2 second interval, where Kamal's own boot wait means "no sleep unless you asked for
  # one". A limit of 1 goes through Sequential rather than Group, because Group also
  # sleeps after the final host.
  def runner_options
    return {} unless limit

    if limit == 1
      { in: :sequence, wait: wait.to_i }
    else
      { in: :groups, limit: limit, wait: wait.to_i }
    end
  end
end
