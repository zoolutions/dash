# `dash autoscale pause ROLE [--for DURATION]`: the controller leaves the role alone until
# `ends_at` (a Time) or for good (`:indefinite`) - `resume ROLE` removes it. Kept as
# `pause/<role>.json` on the state host (Dash::Autoscale::StateStore.host), beside the
# controller's other state.
class Dash::Autoscale::Pause
  INDEFINITE = "indefinite"

  attr_reader :ends_at, :by, :at

  def self.from(hash)
    return unless hash.is_a?(Hash)

    # A pause whose end cannot be read holds: letting go of a role an operator paused is
    # the worse mistake.
    ends_at = hash["until"] == INDEFINITE ? :indefinite : Dash::Autoscale::Timestamp.parse(hash["until"]) || :indefinite
    new(ends_at: ends_at, by: hash["by"], at: Dash::Autoscale::Timestamp.parse(hash["at"]))
  end

  def initialize(ends_at:, by: nil, at: nil)
    @ends_at, @by, @at = ends_at, by, at
  end

  def indefinite?
    @ends_at == :indefinite
  end

  def active?(now)
    indefinite? || now < @ends_at
  end

  def to_h
    { "until" => indefinite? ? INDEFINITE : Dash::Autoscale::Timestamp.dump(@ends_at), "by" => by, "at" => Dash::Autoscale::Timestamp.dump(at) }
  end
end
