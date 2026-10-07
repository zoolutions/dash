require "base64"

# The autoscaling controller's state files, under `<app_directory>/autoscale/` on the
# primary role's first baseline host: `heartbeat.json`, `state.json`, `decisions.jsonl`
# and one `pause/<role>.json` file per paused role. JSON travels base64-encoded and is decoded
# on the host, so no value is ever shell-quoted; a file is written beside its target and
# moved into place, so a reader never sees half of one. See Dash::Autoscale::StateStore.
class Dash::Commands::Autoscale < Dash::Commands::Base
  # What docker allows in a container name, which every role name ends up in.
  ROLE_NAME = /\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/
  PAUSE_EXTENSION = ".json"

  def ensure_directory
    make_directory pause_directory
  end

  def read_heartbeat
    read_file heartbeat_file
  end

  def write_heartbeat(json)
    write_json json, heartbeat_file
  end

  def read_state
    read_file state_file
  end

  def write_state(json)
    write_json json, state_file
  end

  # `lines` are JSON objects, one per line.
  def append_decisions(lines)
    append decode(lines.map { |line| "#{line}\n" }.join), decisions_file
  end

  # The last `lines` entries, or the last `lines` of one role's (the log writes `role` first).
  def read_decisions(lines:, role: nil)
    lines = Integer(lines.to_s, 10)

    if role
      any pipe([ :grep, "-F", Dash::Utils.single_quote(%("role":"#{role_name(role)}")), decisions_file, "2>", "/dev/null" ], [ :tail, "-n", lines ]), [ :true ]
    else
      any [ :tail, "-n", lines, decisions_file, "2>", "/dev/null" ], [ :true ]
    end
  end

  def count_decisions
    any [ :wc, "-l", "<", decisions_file, "2>", "/dev/null" ], [ :echo, 0 ]
  end

  def trim_decisions(keep:)
    combine \
      write([ :tail, "-n", Integer(keep.to_s, 10), decisions_file ], temporary(decisions_file)),
      [ :mv, temporary(decisions_file), decisions_file ]
  end

  def write_pause(role, json)
    write_json json, pause_file(role)
  end

  def remove_pause(role)
    [ :rm, "-f", pause_file(role) ]
  end

  # `<path>:<json>` per file in the pause directory.
  def read_pauses
    any [ :grep, "-H", "\"\"", "#{pause_directory}/*", "2>", "/dev/null" ], [ :true ]
  end

  private
    def write_json(json, file)
      combine \
        write(decode(json), temporary(file)),
        [ :mv, temporary(file), file ]
    end

    def decode(content)
      pipe [ :echo, "\"#{Base64.strict_encode64(content)}\"" ], [ :base64, "-d" ]
    end

    def temporary(file)
      "#{file}.tmp"
    end

    def directory
      File.join(config.app_directory, "autoscale")
    end

    def pause_directory
      File.join(directory, "pause")
    end

    def heartbeat_file
      File.join(directory, "heartbeat.json")
    end

    def state_file
      File.join(directory, "state.json")
    end

    def decisions_file
      File.join(directory, "decisions.jsonl")
    end

    def pause_file(role)
      File.join(pause_directory, "#{role_name(role)}#{PAUSE_EXTENSION}")
    end

    def role_name(role)
      raise ArgumentError, "#{role.to_s.inspect} is not a role name dash can keep autoscale state for" unless ROLE_NAME.match?(role.to_s)

      role.to_s
    end
end
