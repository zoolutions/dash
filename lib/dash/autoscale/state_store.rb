require "json"

# The controller's state, kept on the primary role's first baseline host (never a member,
# which comes and goes) so every operator's CLI and `dash mcp` read the same files with no
# extra configuration: the heartbeat that doubles as the single-controller lease, per-role
# state (unreachable-since times, last scale-out and scale-in), the decision log, and pauses.
#
# Runs Dash::Commands::Autoscale through the SSHKit backend it is handed (call it from
# inside `on(StateStore.host)`). A missing file is empty state; a malformed one is too, with
# one warning per file, so a corrupted file never stops the controller. Reads give
# string-keyed hashes, as JSON has them.
class Dash::Autoscale::StateStore
  def self.host(config = DASH.config)
    config.primary_role.baseline_hosts.first
  end

  def initialize(backend, config: DASH.config)
    @backend = backend
    @config = config
    @commands = Dash::Commands::Autoscale.new(config)
    @warned = Set.new
  end

  def ensure_directory
    execute @commands.ensure_directory
  end

  def heartbeat
    read_object "heartbeat.json", @commands.read_heartbeat
  end

  def write_heartbeat(heartbeat)
    execute @commands.write_heartbeat(dump(heartbeat))
  end

  def state
    read_object "state.json", @commands.read_state
  end

  def write_state(state)
    execute @commands.write_state(dump(state))
  end

  # The last `lines` entries of the decision log, oldest first.
  def decisions(lines:)
    capture(@commands.read_decisions(lines: lines)).lines.filter_map { |line| parse("decisions.jsonl", line) if line.strip.present? }
  end

  # Decisions or hashes.
  def append_decisions(decisions)
    return if decisions.empty?

    execute @commands.append_decisions(decisions.map { |decision| dump(decision.to_h) })
  end

  def decision_count
    Integer(capture(@commands.count_decisions).strip.presence || "0", 10)
  end

  def trim_decisions(keep:)
    execute @commands.trim_decisions(keep: keep)
  end

  # { role => pause }
  def pauses
    capture(@commands.read_pauses).lines.each_with_object({}) do |line, pauses|
      path, json = line.chomp.split(":", 2)
      role = File.basename(path)
      # A `.tmp` an interrupted write left behind is no pause: role names carry no dot.
      next if json.blank? || !Dash::Commands::Autoscale::ROLE_NAME.match?(role)

      pause = parse("pause/#{role}", json)
      pauses[role] = pause if pause
    end
  end

  def write_pause(role, pause)
    execute @commands.write_pause(role, dump(pause))
  end

  def remove_pause(role)
    execute @commands.remove_pause(role)
  end

  private
    def read_object(file, command)
      output = capture(command)
      output.strip.empty? ? {} : parse(file, output) || {}
    end

    def parse(file, json)
      value = JSON.parse(json)
      value.is_a?(Hash) ? value : malformed(file)
    rescue JSON::ParserError
      malformed(file)
    end

    def malformed(file)
      if @warned.add?(file)
        warn "#{File.join(@config.app_directory, "autoscale", file)} on #{self.class.host(@config)} is not valid JSON, treating it as empty"
      end

      nil
    end

    def dump(value)
      JSON.generate(Dash::Autoscale::Decision.json_safe(value))
    end

    def capture(command)
      @backend.capture(*command, verbosity: :debug)
    end

    def execute(command)
      @backend.execute(*command)
    end
end
