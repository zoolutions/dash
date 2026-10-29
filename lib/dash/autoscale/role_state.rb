# What the controller remembers about one scaled role between ticks, in `state.json` on
# the state host so a restart or a `--once` run from cron carries on where the last tick
# stopped: when it last scaled out and in (cooldown), when each member it joined came up
# (warmup), since when each started member has not answered (replacement after
# `boot_timeout`), since when its signal has been above or below its band (`up.for`,
# `down.for`), and the last decision it logged (the log only takes changes).
#
# The bridge between the file (string keys, ISO 8601 strings) and Dash::Autoscale::Policy
# (symbols, Time).
class Dash::Autoscale::RoleState
  attr_reader :unreachable, :joined, :last_decision

  def self.from(hash)
    hash = hash.is_a?(Hash) ? hash : {}

    new(last_scale_out_at: Dash::Autoscale::Timestamp.parse(hash["last_scale_out_at"]),
      last_scale_in_at: Dash::Autoscale::Timestamp.parse(hash["last_scale_in_at"]),
      unreachable: times(hash["unreachable"]), joined: times(hash["joined"]),
      last_decision: hash["last_decision"].is_a?(Hash) ? hash["last_decision"] : nil,
      above_since: Dash::Autoscale::Timestamp.parse(hash["above_since"]), below_since: Dash::Autoscale::Timestamp.parse(hash["below_since"]))
  end

  def self.times(hash)
    return {} unless hash.is_a?(Hash)

    hash.filter_map { |host, time| [ host, Dash::Autoscale::Timestamp.parse(time) ] if Dash::Autoscale::Timestamp.parse(time) }.to_h
  end

  def initialize(last_scale_out_at: nil, last_scale_in_at: nil, unreachable: {}, joined: {}, last_decision: nil, above_since: nil, below_since: nil)
    @last_scale_out_at, @last_scale_in_at = last_scale_out_at, last_scale_in_at
    @unreachable, @joined, @last_decision = unreachable, joined, last_decision
    @above_since, @below_since = above_since, below_since
  end

  def history
    { last_scale_out_at: @last_scale_out_at, last_scale_in_at: @last_scale_in_at }
  end

  def breach
    { above_since: @above_since, below_since: @below_since }
  end

  # Every sample moves the breach windows before the policy reads them: above the band the
  # above window starts (or keeps its start), below it the below window does, and inside
  # the band - or without a number to compare - both end. A gap in samples restarts a window.
  def observe_signal(sample, up_above:, down_below:)
    if sample.nil? || sample.missing?
      @above_since = @below_since = nil
    elsif sample.value > up_above
      @above_since ||= sample.at
      @below_since = nil
    elsif sample.value < down_below
      @below_since ||= sample.at
      @above_since = nil
    else
      @above_since = @below_since = nil
    end
  end

  # The members that did not answer this tick: each keeps the time it was first seen
  # unreachable, a new one starts now, and one that answered again is forgotten.
  def observe_unreachable(hosts, now:)
    @unreachable = hosts.to_h { |host| [ host, @unreachable.fetch(host, now) ] }
  end

  def joined_at(hosts, now:)
    hosts.each { |host| @joined[host] = now }
  end

  # Only the members still started can be warming up.
  def keep_members(hosts)
    @joined = @joined.slice(*hosts)
  end

  def scaled(action, now:)
    case action
    when "scale_out" then @last_scale_out_at = now
    when "scale_in" then @last_scale_in_at = now
    end
  end

  def forget(host)
    @unreachable = @unreachable.except(host)
    @joined = @joined.except(host)
  end

  # Every action is logged; a hold only when its action or reasons differ from the last
  # decision logged, so a steady role adds nothing to the log tick after tick.
  def log?(decision)
    !decision.hold? || last_decision != logged_shape(decision)
  end

  def logged(decision)
    @last_decision = logged_shape(decision)
  end

  def to_h
    { "last_scale_out_at" => Dash::Autoscale::Timestamp.dump(@last_scale_out_at),
      "last_scale_in_at" => Dash::Autoscale::Timestamp.dump(@last_scale_in_at),
      "unreachable" => @unreachable.transform_values { |time| Dash::Autoscale::Timestamp.dump(time) },
      "joined" => @joined.transform_values { |time| Dash::Autoscale::Timestamp.dump(time) },
      "last_decision" => @last_decision }
      .merge({ "above_since" => Dash::Autoscale::Timestamp.dump(@above_since), "below_since" => Dash::Autoscale::Timestamp.dump(@below_since) }.compact)
  end

  private
    def logged_shape(decision)
      { "action" => decision.action, "reasons" => decision.reasons }
    end
end
