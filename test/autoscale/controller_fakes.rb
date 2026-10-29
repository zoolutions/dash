# What Dash::Autoscale::Controller talks to - the state host's files, Dash::Cli::Autoscale,
# the signal reader - as in-memory stand-ins that record what they were asked.
module AutoscaleControllerFakes
  # The in-memory stand-in for the files on the state host, JSON round-tripped like them.
  class FakeStore
    attr_accessor :files, :decisions, :writes, :trimmed, :count

    def initialize
      @files = { "heartbeat" => {}, "state" => {}, "pauses" => {} }
      @decisions = []
      @writes = []
      @count = 0
    end

    def ensure_directory; end

    def heartbeat = files["heartbeat"]
    def state = files["state"]
    def pauses = files["pauses"]
    def decision_count = count

    def write_heartbeat(value) = write("heartbeat", value)

    def write_heartbeat_if_held(id, value)
      return false unless heartbeat.empty? || heartbeat["controller_id"] == id

      write("heartbeat", value)
      true
    end
    def write_state(value) = write("state", value)

    def append_decisions(decisions)
      return if decisions.empty?

      @writes << "decisions"
      @decisions.concat(decisions.map { |decision| round_trip(decision.to_h) })
    end

    def trim_decisions(keep:)
      @trimmed = keep
    end

    private
      def write(file, value)
        @writes << file
        files[file] = round_trip(value)
      end

      def round_trip(value)
        JSON.parse(JSON.generate(Dash::Autoscale::Decision.json_safe(value)))
      end
  end

  # What Dash::Cli::Autoscale does for the controller, recorded.
  class FakeCli
    attr_reader :scale_sets, :replaced, :reports
    attr_accessor :on_scale_set, :on_replace

    def initialize(config_file)
      @config_file = config_file
      @scale_sets, @replaced, @reports = [], [], []
    end

    def reconfigure!
      DASH.reconfigure(config_file: @config_file)
    end

    def invoke_scale_set(role, count)
      @scale_sets << [ role.name, count ]
      on_scale_set&.call(role, count)
    end

    def replace_member(role, member, count:)
      @replaced << [ role.name, member.host, count ]
      on_replace&.call(role, member)
    end

    def report(message, _color = nil)
      @reports << message
    end
  end

  # Every role's signal reads `value` (or fails with `error`), its one guard `guard_value`.
  class FakeReader
    attr_accessor :value, :error, :guard_value, :raises
    attr_reader :closed, :reads

    def initialize
      @guard_value = 0
      @reads = 0
    end

    def read(_role, at:)
      @reads += 1
      raise raises if raises

      [ Dash::Autoscale::Sample.new(value: value, at: at, error: error),
        [ Dash::Autoscale::Guard::Reading.new(index: 0, source: "postgres", above: 180, sample: Dash::Autoscale::Sample.new(value: guard_value, at: at)) ] ]
    end

    def close
      @closed = true
    end
  end
end
