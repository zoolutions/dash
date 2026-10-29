require "test_helper"

class AutoscaleConnectionsTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :closed

    def close
      @closed = true
    end

    def alive?
      !closed
    end
  end

  setup do
    @built = []
    @tunnels = []
    @urls = { redis: "redis://cache.internal:6379/0", postgres: "postgres://app@db.internal/app", prometheus: "http://10.0.0.9:9090" }
    @via = {}
  end

  test "builds a client once per source and hands it to every read" do
    connections = build_connections
    first = connections.with(:redis) { |client| client }
    second = connections.with(:redis) { |client| client }

    assert_same first, second
    assert_equal [ [ :redis, "redis://cache.internal:6379/0", nil ] ], @built
  end

  test "an error drops the client, and the next read builds a new one" do
    connections = build_connections
    client = connections.with(:redis) { |redis| redis }

    assert_raises(RuntimeError) { connections.with(:redis) { raise "Connection reset by peer" } }
    assert client.closed

    assert_not_same client, connections.with(:redis) { |redis| redis }
    assert_equal 2, @built.size
  end

  test "a changed URL (a reconfigured deploy.yml) builds a new client and closes the old one" do
    connections = build_connections
    old = connections.with(:redis) { |client| client }
    @urls[:redis] = "redis://cache2.internal:6379/0"

    assert_not_same old, connections.with(:redis) { |client| client }
    assert old.closed
  end

  test "via opens a tunnel to the URL's host and port (or the source's default port) first" do
    @via[:postgres] = "10.0.0.31"
    connections = build_connections
    connections.with(:postgres) { }

    assert_equal [ [ "10.0.0.31", "db.internal", 5432 ] ], @tunnels.map(&:first)
    assert_equal [ :postgres, "postgres://app@db.internal/app", @tunnels.first.last ], @built.last
  end

  test "a tunnel whose session died is replaced with the client it carried" do
    @via[:redis] = "10.0.0.31"
    connections = build_connections
    old = connections.with(:redis) { |client| client }
    @tunnels.first.last.close

    assert_not_same old, connections.with(:redis) { |client| client }
    assert old.closed
    assert_equal 2, @tunnels.size
  end

  test "close closes every client and tunnel" do
    @via[:redis] = "10.0.0.31"
    connections = build_connections
    redis = connections.with(:redis) { |client| client }
    prometheus = connections.with(:prometheus) { |client| client }

    connections.close

    assert redis.closed
    assert prometheus.closed
    assert @tunnels.first.last.closed
  end

  test "a configuration error is raised as it is, and builds nothing" do
    autoscale = stub(source_via: nil)
    autoscale.stubs(:source_url).raises(Dash::ConfigurationError, "autoscale/redis/url: secret 'REDIS_URL' resolved to an empty value")
    connections = Dash::Autoscale::Connections.new(config: -> { stub(autoscale: autoscale) }, builder: method(:fake_build), tunnel: method(:fake_tunnel))

    assert_raises(Dash::ConfigurationError) { connections.with(:redis) { } }
    assert_empty @built
  end

  test "redis through a tunnel connects to it, everything else from the URL" do
    assert_equal({ url: "redis://cache.internal:6379/0", connect_timeout: 2, read_timeout: 5, write_timeout: 5 },
      Dash::Autoscale::Connections::Builder.redis_options("redis://cache.internal:6379/0", nil))
    assert_equal({ url: "redis://cache.internal:6379/0", host: "127.0.0.1", port: 54_321, connect_timeout: 2, read_timeout: 5, write_timeout: 5 },
      Dash::Autoscale::Connections::Builder.redis_options("redis://cache.internal:6379/0", stub(address: "127.0.0.1", port: 54_321)))
  end

  test "postgres through a tunnel connects to hostaddr and keeps host for TLS" do
    parsed = { host: "db.internal", port: "5432", dbname: "app", user: "app", sslmode: "verify-full" }

    assert_equal parsed.merge(connect_timeout: 5), Dash::Autoscale::Connections::Builder.postgres_options(parsed, nil)
    assert_equal parsed.merge(hostaddr: "127.0.0.1", port: 54_321, connect_timeout: 5),
      Dash::Autoscale::Connections::Builder.postgres_options(parsed, stub(address: "127.0.0.1", port: 54_321))
  end

  test "a driver gem that is not installed names the gem to add" do
    Dash::Autoscale::Connections::Builder.stubs(:require).with("redis-client").raises(LoadError, "cannot load such file -- redis-client")

    error = assert_raises(Dash::ConfigurationError) { Dash::Autoscale::Connections::Builder.build(:redis, "redis://cache:6379", nil, config: nil) }
    assert_match %(autoscale/redis: needs the redis-client gem - add gem "redis-client" to the Gemfile dash autoscale runs with), error.message
  end

  private
    def build_connections
      urls, via = @urls, @via
      autoscale = Object.new
      autoscale.define_singleton_method(:source_url) { |source| urls.fetch(source.to_sym) }
      autoscale.define_singleton_method(:source_via) { |source| via[source.to_sym] }
      config = Struct.new(:autoscale).new(autoscale)

      Dash::Autoscale::Connections.new(config: -> { config }, builder: method(:fake_build), tunnel: method(:fake_tunnel))
    end

    def fake_build(source, url, tunnel, config:)
      @built << [ source, url, tunnel ]
      FakeClient.new
    end

    def fake_tunnel(via, host, port)
      FakeClient.new.tap { |tunnel| @tunnels << [ [ via, host, port ], tunnel ] }
    end
end
