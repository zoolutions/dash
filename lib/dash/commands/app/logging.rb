require "shellwords"

module Dash::Commands::App::Logging
  # `since` and `grep` are quoted and `lines` must be a number, so none of them can end
  # the command they sit in. `dash mcp` hands them over from an agent, not an operator.
  # `grep_options` is the operator's own extra flags and stays raw.
  def logs(container_id: nil, timestamps: true, since: nil, lines: nil, grep: nil, grep_options: nil)
    pipe \
      container_id_command(container_id),
      "xargs docker logs#{" --timestamps" if timestamps}#{" --since #{since.to_s.shellescape}" if since}#{" --tail #{Integer(lines.to_s, 10)}" if lines} 2>&1",
      ("grep #{Dash::Utils.single_quote(grep)}#{" #{grep_options}" if grep_options}" if grep)
  end

  # Every replica slot's logs in one round trip, each slot's after a `separator` line. Log
  # lines are anyone's text, so the caller picks a separator no log line can guess.
  def replica_logs(separator:, **options)
    chain(*role.replica_numbers.flat_map { |replica| [ [ :echo, separator ], for_replica(replica).logs(**options) ] })
  end

  def follow_logs(host:, container_id: nil, timestamps: true, lines: nil, grep: nil, grep_options: nil)
    run_over_ssh \
      pipe(
        container_id_command(container_id),
        "xargs docker logs#{" --timestamps" if timestamps}#{" --tail #{lines}" if lines} --follow 2>&1",
        (%(grep "#{grep}"#{" #{grep_options}" if grep_options}) if grep)
      ),
      host: host
  end

  private

  def container_id_command(container_id)
    case container_id
    when Array then container_id
    when String, Symbol then shell([ "echo #{container_id}" ])
    else current_running_container_id
    end
  end
end
