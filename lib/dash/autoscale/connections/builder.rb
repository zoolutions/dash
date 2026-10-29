# How each source's client is made. redis-client and pg are not dash dependencies: they are
# required here, on first use, and a missing one names the gem to add to the Gemfile the
# controller runs with.
module Dash::Autoscale::Connections::Builder
  GEMS = { redis: "redis-client", postgres: "pg" }.freeze
  CONNECT_TIMEOUT = 2
  READ_TIMEOUT = 5
  POSTGRES_CONNECT_TIMEOUT = 5

  def self.build(source, url, tunnel, config:)
    case source
    when :redis
      load_gem(source)
      RedisClient.new(**redis_options(url, tunnel))
    when :postgres
      load_gem(source)
      PG.connect(postgres_options(conninfo(url), tunnel))
    when :prometheus
      Dash::Autoscale::PrometheusClient.new(url: url, token: config.autoscale.prometheus_token, tunnel: tunnel)
    end
  end

  # redis-client takes host and port over the URL's, and keeps the rest (password, db).
  def self.redis_options(url, tunnel)
    { url: url, **({ host: tunnel.address, port: tunnel.port } if tunnel).to_h,
      connect_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: READ_TIMEOUT }
  end

  # libpq connects to `hostaddr` and verifies TLS against `host`, so a tunnel only sets
  # hostaddr and port.
  def self.postgres_options(conninfo, tunnel)
    conninfo.merge(**({ hostaddr: tunnel.address, port: tunnel.port } if tunnel).to_h, connect_timeout: POSTGRES_CONNECT_TIMEOUT)
  end

  # The URL as libpq reads it, so nothing in it is lost when a tunnel changes where it goes.
  def self.conninfo(url)
    PG::Connection.conninfo_parse(url).each_with_object({}) { |option, hash| hash[option[:keyword].to_sym] = option[:val] if option[:val] }
  end

  def self.load_gem(source)
    require GEMS.fetch(source)
  rescue LoadError
    gem = GEMS.fetch(source)
    raise Dash::ConfigurationError, %(autoscale/#{source}: needs the #{gem} gem - add gem "#{gem}" to the Gemfile dash autoscale runs with)
  end
end
