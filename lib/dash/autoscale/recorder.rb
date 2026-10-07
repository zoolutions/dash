require "json"

# `dash autoscale run --record FILE`: every tick's decisions, with every policy input they
# were made from, appended to a local JSONL file - one line per tick - for replaying later.
class Dash::Autoscale::Recorder
  def initialize(path)
    @path = path
  end

  def record(at, decisions)
    File.open(@path, "a") { |file| file.puts JSON.generate(at: Dash::Autoscale::Timestamp.dump(at), decisions: decisions.map(&:to_h)) }
  end
end
