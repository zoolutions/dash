# How a container of a role without the proxy leaves when it is scaled in: an optional
# signal (e.g. TSTP, so Sidekiq stops fetching), then a wait, then `docker stop`. A
# proxied role has none - dash-proxy drains it.
class Dash::Configuration::Role::Drain
  # The Linux signal names `docker kill --signal` accepts, without the SIG prefix.
  SIGNALS = %w[
    HUP INT QUIT ILL TRAP ABRT IOT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT
    STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO POLL PWR SYS
  ]

  attr_reader :context

  def initialize(drain_config:, context:)
    @drain_config = drain_config || {}
    @context = context
    validate!
  end

  def signal
    @drain_config["signal"]&.to_s
  end

  def wait
    @drain_config.fetch("wait", 0)
  end

  def configured?
    @drain_config.present?
  end

  private
    def validate!
      return if signal.nil? || signal.match?(/\A\d+\z/) || SIGNALS.include?(signal.upcase.delete_prefix("SIG"))

      raise Dash::ConfigurationError, "#{context}/signal: #{signal} is not a signal docker can send"
    end
end
