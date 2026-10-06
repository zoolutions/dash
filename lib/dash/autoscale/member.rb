# A pool member as the provider reports it: its provider id, the address dash connects to,
# the role it carries in its labels (all of them under `labels`), and its power state. `verified: false` marks a member
# named with --hosts while the provider could not be asked (see Dash::Autoscale::Pool).
Dash::Autoscale::Member = Struct.new(:id, :host, :role, :state, :labels, :created_at, :verified, keyword_init: true) do
  def initialize(verified: true, **attributes)
    super
  end

  def started?
    state == "started"
  end

  def stopped?
    state == "stopped"
  end

  # Neither on nor off: UpCloud reports `maintenance` while a server starts, stops or is
  # changed, and `error` when it cannot.
  def transitional?
    !started? && !stopped?
  end

  def to_h
    { id: id, host: host, role: role, state: state, labels: labels, created_at: created_at, verified: verified }
  end
end

Dash::Autoscale::Member::STATES = %w[ started stopped maintenance error ].freeze
