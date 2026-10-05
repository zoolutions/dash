# Whether this destination's deploy lock is held on the primary host, and by whom, since
# when, at which version and why.
class Dash::Diagnostics::Lock < Dash::Diagnostics::Base
  # "Locked by: Jane at 2026-10-05T10:00:00Z", "Version: 999", "Message: ..."
  LOCKED_BY = /\ALocked by: (?<locked_by>.*) at (?<locked_at>\S+)\z/

  # The lock lives on the configured primary host whatever --hosts narrows to; asking any
  # other host would answer "not held" for a lock that is.
  def initialize(host: DASH.config.primary_host)
    @host = host
  end

  private
    def snapshot
      { lock: per_host([ @host ]) { |backend, _host| details(backend.capture_with_info(*DASH.lock.status, raise_on_non_zero_exit: false)) }.first }
    end

    # The status command fails, and prints nothing, when there is no lock directory.
    def details(output)
      return { held: false } if output.blank?

      fields = output.lines.filter_map { |line| line.chomp.split(": ", 2) if line.include?(": ") }.to_h
      locked_by = LOCKED_BY.match("Locked by: #{fields["Locked by"]}")

      { held: true, locked_by: locked_by&.[](:locked_by), locked_at: locked_by&.[](:locked_at), version: fields["Version"], message: fields["Message"] }
    end
end
