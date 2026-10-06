# Blanks credentials out of a diagnostic before it leaves the process for an agent.
#
# Two passes, because neither is enough alone:
#
# - By key: any value under a key that names a credential (`password`, `token`, `secret`,
#   `key`) or a secret from `.dash/secrets` becomes "[REDACTED]", whole subtree and all.
#   This over-redacts on purpose (`ssh_options.keys`, any `*_key` setting) - a hidden
#   setting costs a question, a leaked one costs a rotation.
# - By value: every secret value from `.dash/secrets` is replaced wherever it appears
#   inside any string, so a password embedded in a `DATABASE_URL`, an audit line, a log
#   line or an SSH error message is caught too. Values shorter than MINIMUM_VALUE_LENGTH
#   are left to the key pass, or a secret like "1" would blank every number.
class Dash::Diagnostics::Redactor
  REDACTED = "[REDACTED]"
  CREDENTIAL_KEY = /password|token|secret|key/i
  MINIMUM_VALUE_LENGTH = 6

  # Resolving the secrets runs any command substitution in `.dash/secrets` (a password
  # manager), so build this once per process, not per question.
  def self.for(config)
    new(secrets: config.secrets.to_h)
  end

  def initialize(secrets: {})
    @names = secrets.keys.map(&:to_s).to_set
    values = secrets.values.map(&:to_s).select { |value| value.length >= MINIMUM_VALUE_LENGTH }.uniq
    @pattern = Regexp.union(values.sort_by { |value| -value.length }) if values.any?
  end

  def redact(value)
    case value
    when Dash::Utils::Sensitive then value.redaction
    when Hash then value.to_h { |key, nested| [ key, credential_key?(key) ? REDACTED : redact(nested) ] }
    when Array then value.map { |element| redact(element) }
    when String then redact_text(value)
    else value
    end
  end

  def redact_text(text)
    @pattern ? text.to_s.gsub(@pattern, REDACTED) : text.to_s
  end

  private
    def credential_key?(key)
      key.to_s.match?(CREDENTIAL_KEY) || @names.include?(key.to_s)
    end
end
