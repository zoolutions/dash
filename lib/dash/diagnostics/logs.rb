require "securerandom"

# The tail of a role's containers on its hosts, every replica slot - or of an accessory's
# container on its hosts - for `dash mcp`.
#
# Built for input nobody vetted: an agent chooses the role, hosts, `lines`, `since` and
# `grep`. The role and hosts are looked up in the configuration, `lines` is bounded,
# `since` must look like a duration or a timestamp, and `grep` never reaches a shell at
# all - it is a plain substring match, applied here, after the capture.
class Dash::Diagnostics::Logs < Dash::Diagnostics::Base
  # "42m", "1h30m", "2026-10-05", "2026-10-05T10:00:00Z", "2026-10-05T10:00:00+02:00"
  SINCE = /\A(?:(?:\d+[smh])+|\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)?)\z/
  MAX_GREP_LENGTH = 200

  # With a redactor, lines are redacted before grep sees them: matching raw lines would let a
  # grep probe a secret one guessed character at a time.
  # Either a role (every replica slot) or an accessory (its one container on each host).
  def initialize(role: nil, accessory: nil, hosts: nil, lines: 100, since: nil, grep: nil, redactor: nil)
    @redactor = redactor
    @accessory = accessory
    @role = role || (DASH.primary_role unless accessory)
    @hosts = hosts || (accessory ? accessory.hosts & DASH.accessory_hosts : @role.hosts & DASH.hosts)
    @lines = Dash::Diagnostics::Lines.bounded(lines)
    @since = validated_since(since)
    @grep = validated_grep(grep)
  end

  private
    def snapshot
      if @accessory
        { accessory: @accessory.name, hosts: per_host(@hosts) { |backend, _host| { lines: accessory_lines(backend) } } }
      else
        { role: @role.name, hosts: per_host(@hosts) { |backend, host| { replicas: replicas(backend, host) } } }
      end
    end

    def accessory_lines(backend)
      output = backend.capture_with_info(*DASH.accessory(@accessory.name).logs(lines: @lines, since: @since), raise_on_non_zero_exit: false)
      matching(output.lines.map { |line| redacted(line.chomp) })
    end

    # One capture for every slot on the host, split back apart on a separator made for this
    # read alone: a fixed one could be printed by the app to shift lines between slots.
    def replicas(backend, host)
      separator = "--dash-replica-#{SecureRandom.hex(8)}--"
      command = DASH.app(role: @role, host: host).replica_logs(separator: separator, lines: @lines, since: @since)
      slots = backend.capture_with_info(*command, raise_on_non_zero_exit: false).split(/^#{Regexp.escape(separator)}\n?/, -1).drop(1)

      @role.replica_numbers.each_with_index.map do |replica, index|
        { replica: replica, lines: matching(slots[index].to_s.lines.map { |line| redacted(line.chomp) }) }
      end
    end

    def redacted(line)
      @redactor ? @redactor.redact_text(line) : line
    end

    def matching(lines)
      @grep ? lines.select { |line| line.include?(@grep) } : lines
    end

    def validated_since(since)
      return if since.blank?
      raise ArgumentError, "since must be a duration like 42m or 1h30m, or a timestamp like 2026-10-05T10:00:00Z, got #{since.inspect}" unless since.to_s.match?(SINCE)

      since.to_s
    end

    def validated_grep(grep)
      return if grep.blank?
      raise ArgumentError, "grep must be at most #{MAX_GREP_LENGTH} characters" if grep.to_s.length > MAX_GREP_LENGTH

      grep.to_s
    end
end
