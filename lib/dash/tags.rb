require "time"

class Dash::Tags
  attr_reader :config, :tags

  class << self
    def from_config(config, **extra)
      new(**default_tags(config), **extra)
    end

    def default_tags(config)
      { recorded_at: Time.now.utc.iso8601,
        performer: Dash::Git.email.presence || `whoami`.chomp,
        destination: config.destination,
        version: config.version,
        service_version: service_version(config),
        service: config.service }
    end

    def service_version(config)
      [ config.service, config.abbreviated_version ].compact.join("@")
    end
  end

  def initialize(**tags)
    @tags = tags.compact
  end

  # Both prefixes carry the same value: hooks are operator-written and apps read
  # these at runtime, so the old names stay until 5.0 (zoolutions/dash#118).
  def env
    tags.each_with_object({}) do |(detail, value), env|
      env["DASH_#{detail.upcase}"] = value
      env["KAMAL_#{detail.upcase}"] = value
    end
  end

  def to_s
    tags.values.map { |value| "[#{value}]" }.join(" ")
  end

  def except(*tags)
    self.class.new(**self.tags.except(*tags))
  end
end
