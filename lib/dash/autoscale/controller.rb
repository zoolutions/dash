require "securerandom"
require "socket"

# `dash autoscale run`: every `autoscale.interval` seconds, for each scaled role with a
# `scale.schedule`, observe it, ask Dash::Autoscale::Policy, and carry the decision out
# through `dash scale set` (or replace an unreachable member) under the deploy lock -
# never by building a join itself.
#
# Its state lives on the primary host (Dash::Autoscale::StateStore) and is read at the
# start of every tick, so a restart or a `--once` run from cron behaves like the long-lived
# loop. The heartbeat is the lease: a second controller refuses to start while it is
# alive, and this one stops when it names another controller.
#
# A failure in one role becomes that role's `action_failed` (or `lock_busy`) hold and the
# tick moves on. A tick that fails as a whole (the primary host down) is reported and the
# loop goes on; only a lost lease or a deploy.yml that no longer loads stops it.
class Dash::Autoscale::Controller
  include SSHKit::DSL

  DECISION_LOG_LIMIT = 10_000
  TRIM_CHECK_INTERVAL = 3600

  # One scaled role on one tick: the state it is carried in, how it was evaluated, and
  # what was decided (or what became of the decision once carried out).
  Entry = Struct.new(:role, :state, :evaluation, :decision, keyword_init: true)

  attr_reader :id, :metrics, :cli

  # `cli` reconfigures DASH, runs `dash scale set`, replaces members and prints - see
  # Dash::Cli::Autoscale.
  def initialize(cli:, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep seconds }, dry_run: false, takeover: false,
    interval: nil, mode: "loop", recorder: nil, metrics: Dash::Autoscale::Metrics.new)
    @cli, @clock, @sleeper = cli, clock, sleeper
    @dry_run, @takeover, @interval, @mode = dry_run, takeover, interval, mode
    @recorder, @metrics = recorder, metrics
    @id = SecureRandom.hex(8)
    @stopping = false
  end

  def dry_run?
    @dry_run
  end

  def interval
    @interval || DASH.config.autoscale.interval
  end

  # The roles the controller owns the count of: scaled, with a schedule, within --roles.
  def roles
    (DASH.specific_roles || DASH.config.roles).select { |role| role.scaled? && role.scale.schedule.any? }
  end

  # Claims the lease, unless another controller's is alive.
  def start
    cli.reconfigure!
    raise ArgumentError, "No scaled role in scope has a scale/schedule, so there is nothing for the controller to do" if roles.empty?

    @started_at = @clock.call
    return if dry_run?

    # Raised out here: SSHKit would wrap anything raised inside `on`.
    lease = with_store { |store| store.ensure_directory; Dash::Autoscale::Lease.new(store.heartbeat, now: @started_at) }
    if lease.held_by_another?(id) && !@takeover
      raise Dash::Autoscale::LeaseHeld, "Another autoscale controller is running: #{lease.describe}. Stop it, or start this one with --takeover"
    end

    with_store { |store| store.write_heartbeat(heartbeat(@started_at)) }
  end

  def run
    start

    until @stopping
      tick_started = @clock.call
      tick_reporting_failure
      wait_until(tick_started + interval)
    end
  ensure
    release
  end

  # From a signal handler: only a flag, the current tick (and a join in flight) finishes.
  def stop!
    @stopping = true
  end

  def stopping?
    @stopping
  end

  def tick
    started = monotonic
    now = @clock.call
    cli.reconfigure!

    heartbeat, state, pauses = read_state
    ensure_lease(heartbeat)

    entries = roles.map { |role| evaluate(role, now, state, pauses) }
    execute(entries) unless dry_run?
    persist(entries, state, now) unless dry_run?

    decisions = entries.map(&:decision)
    @metrics.record_tick(decisions: decisions, at: @clock.call, duration: monotonic - started,
      members: entries.to_h { |entry| [ entry.role.name, entry.evaluation&.observation&.pool.to_a.map(&:state) ] })
    @recorder&.record(now, decisions)
    decisions.each { |decision| cli.report decision.summary, (:red if decision.error) }
    decisions
  end

  # Marks the heartbeat stopped, so the next controller does not wait out a stale lease -
  # unless another controller holds it by now.
  def release
    return if dry_run? || @started_at.nil?

    with_store do |store|
      if store.heartbeat["controller_id"] == id
        store.write_heartbeat(heartbeat(@last_tick_at || @started_at).merge(stopped_at: @clock.call))
      end
    end
  rescue StandardError => e
    cli.report "Could not mark the autoscale controller stopped: #{e.class}: #{e.message}", :yellow
  end

  private
    def tick_reporting_failure
      tick
    rescue Dash::Autoscale::LeaseLost, Dash::ConfigurationError
      raise
    rescue StandardError => e
      cli.report "Autoscale tick failed: #{e.class}: #{e.message}", :red
    end

    def wait_until(deadline)
      while !@stopping && (remaining = deadline - @clock.call) > 0
        @sleeper.call([ remaining, 1 ].min)
      end
    end

    def read_state
      quietly do
        with_store { |store| [ store.heartbeat, store.state, store.pauses ] }
      end
    end

    def ensure_lease(heartbeat)
      return if dry_run? || heartbeat["controller_id"].blank? || heartbeat["controller_id"] == id

      raise Dash::Autoscale::LeaseLost, "Another autoscale controller took over: #{Dash::Autoscale::Lease.new(heartbeat, now: @clock.call).describe}"
    end

    def evaluate(role, now, state, pauses)
      entry = Entry.new(role: role, state: Dash::Autoscale::RoleState.from(state.dig("roles", role.name)))
      entry.evaluation = Dash::Autoscale::Evaluation.new(role: role, now: now, state: entry.state, pause: Dash::Autoscale::Pause.from(pauses[role.name]),
        observation: quietly { Dash::Autoscale::Observation.take(role) })
      entry.decision = entry.evaluation.decide
      entry
    rescue StandardError => e
      entry.evaluation = nil
      entry.decision = Dash::Autoscale::Decision.new(role: role.name, action: "hold", reasons: [ "action_failed" ], at: now, error: "#{e.class}: #{e.message}")
      entry
    end

    # Taking the deploy lock first ensures the run directory on every host of the app, and
    # a host that did not answer this tick would fail that for every role. The hosts this
    # tick saw down are skipped for it (the trick Dash::Cli::Scale#replace_unreachable uses
    # for its own member).
    def execute(entries)
      skipped = entries.flat_map { |entry| entry.evaluation&.observation&.unread_hosts.to_a }.uniq - DASH.run_directory_ensured_on
      DASH.run_directory_ensured_on.concat(skipped)

      entries.each { |entry| entry.decision = carry_out(entry) unless entry.decision.hold? }
    ensure
      skipped&.each { |host| DASH.run_directory_ensured_on.delete(host) }
    end

    def carry_out(entry)
      role, decision, observation = entry.role, entry.decision, entry.evaluation.observation

      case decision.action
      when "scale_out", "scale_in"
        cli.invoke_scale_set(role, decision.to)
        entry.state.scaled(decision.action, now: @clock.call)
        record_joins(entry, observation.member_hosts) if decision.action == "scale_out"
      when "replace_member"
        member = observation.members.find { |candidate| candidate.host == decision.member_host }
        cli.replace_member(role, member, count: decision.from)
        entry.state.forget(member.host)
      end

      decision
    rescue Dash::Cli::LockError => e
      failed(decision, "lock_busy", e.message)
    rescue StandardError => e
      failed(decision, "action_failed", "#{e.class}: #{e.message}")
    end

    # The members a scale-out powered on warm up from now. Members someone else joined are
    # not known to be warming, so they never hold a scale-in.
    def record_joins(entry, before)
      DASH.config.pool.refresh!
      entry.state.joined_at(entry.role.active_members.map(&:host) - before, now: @clock.call)
    end

    def failed(decision, reason, message)
      Dash::Autoscale::Decision.new(role: decision.role, action: "hold", from: decision.from, to: decision.from, reasons: [ reason ],
        inputs: decision.inputs.merge(attempted: { action: decision.action, to: decision.to, replace: decision.member_host }.compact),
        eligible_at: decision.eligible_at, at: decision.at, error: message)
    end

    def persist(entries, state, now)
      logged = entries.select { |entry| entry.state.log?(entry.decision) }.each { |entry| entry.state.logged(entry.decision) }.map(&:decision)
      roles_state = state.fetch("roles", {}).merge(entries.to_h { |entry| [ entry.role.name, entry.state.to_h ] })
      checked_at = Dash::Autoscale::Timestamp.parse(state["decisions_checked_at"])
      check = checked_at.nil? || now - checked_at >= TRIM_CHECK_INTERVAL

      quietly do
        with_store do |store|
          store.append_decisions(logged)
          trim(store) if check
          updated = state.merge("roles" => roles_state, "decisions_checked_at" => Dash::Autoscale::Timestamp.dump(check ? now : checked_at))
          store.write_state(updated) unless updated == state
          store.write_heartbeat(heartbeat(now))
        end
      end

      @last_tick_at = now
    end

    def trim(store)
      store.trim_decisions(keep: DECISION_LOG_LIMIT) if store.decision_count > DECISION_LOG_LIMIT
    end

    def heartbeat(last_tick_at)
      { controller_id: id, hostname: Socket.gethostname, pid: Process.pid, version: Dash::VERSION, mode: @mode,
        started_at: @started_at, last_tick_at: last_tick_at, interval: interval, roles: roles.map(&:name) }
    end

    def with_store(&block)
      result = nil
      on(Dash::Autoscale::StateStore.host) { result = block.call(Dash::Autoscale::StateStore.new(self)) }
      result
    end

    # The controller reads every host every tick; those reads print only with --verbose.
    def quietly(&block)
      DASH.verbosity == :debug ? block.call : DASH.with_verbosity(:error, &block)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
