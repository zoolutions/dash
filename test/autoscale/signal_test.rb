require "test_helper"

class AutoscaleSignalTest < ActiveSupport::TestCase
  test "the reader for the role's signal source" do
    { { "source" => "sidekiq", "queues" => [ "default" ] } => Dash::Autoscale::Signal::Sidekiq,
      { "source" => "pgbus", "queues" => [ "default" ] } => Dash::Autoscale::Signal::Pgbus,
      { "source" => "prometheus", "query" => "max(x)" } => Dash::Autoscale::Signal::Prometheus }.each do |signal, reader|
      config = Dash::Configuration::Role::Scale::Signal.new(signal_config: signal, context: "test")
      role = stub(scale: stub(signal: config))

      built = Dash::Autoscale::Signal.for(role, :connections)
      assert_instance_of reader, built
      assert_equal config, built.config
      assert_equal :connections, built.connections
    end
  end
end
