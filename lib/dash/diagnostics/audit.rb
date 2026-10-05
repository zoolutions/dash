# The last lines of this deploy's audit log on each host, parsed into when, who, the tags
# the line was recorded with (destination, role, ...) and the message.
class Dash::Diagnostics::Audit < Dash::Diagnostics::Base
  # "[2026-10-05T10:00:00Z] [ops@example.com] [staging] [web] Booted app version 999"
  LINE = /\A\[(?<recorded_at>[^\]]*)\] \[(?<performer>[^\]]*)\](?<tags>(?: \[[^\]]*\])*) ?(?<message>.*)\z/

  def initialize(hosts: DASH.hosts, lines: 50)
    @hosts = hosts
    @lines = Dash::Diagnostics::Lines.bounded(lines)
  end

  private
    def snapshot
      { hosts: per_host(@hosts) { |backend, _host| { entries: entries(backend.capture_with_info(*DASH.auditor.reveal(lines: @lines), raise_on_non_zero_exit: false)) } } }
    end

    def entries(output)
      output.lines.map(&:chomp).reject(&:blank?).map { |line| entry(line) }
    end

    def entry(line)
      if (match = LINE.match(line))
        { recorded_at: match[:recorded_at], performer: match[:performer], tags: match[:tags].scan(/\[([^\]]*)\]/).flatten, message: match[:message] }
      else
        { message: line }
      end
    end
end
