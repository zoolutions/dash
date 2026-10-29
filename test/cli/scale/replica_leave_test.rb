require "test_helper"

# A worker replica leaving: its hostname read, the drain signal sent, then the wait - which
# a Sidekiq role ends as soon as Sidekiq reports nothing busy in the leaving containers.
class CliScaleReplicaLeaveTest < ActiveSupport::TestCase
  class FakeBackend
    attr_reader :calls

    def initialize(hostnames: {})
      @hostnames = hostnames
      @calls = []
    end

    def execute(*args)
      @calls << [ :execute, args.flatten.join(" ") ]
    end

    def capture_with_info(*args)
      command = args.flatten.join(" ")
      @calls << [ :capture, command ]
      hostname = @hostnames.find { |name, _| command.include?(name) }&.last
      raise SSHKit::Command::Failed, "no such container" if hostname.is_a?(Exception)

      "#{hostname}\n"
    end

    def info(message)
      @calls << [ :info, message ]
    end
  end

  class FakeBusy
    attr_reader :asked

    def initialize(*answers)
      @answers = answers
      @asked = []
    end

    def busy(hostnames)
      @asked << hostnames
      answer = @answers.length > 1 ? @answers.shift : @answers.first
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  setup do
    @role = stub(running_proxy?: false, drain_signal: "TSTP", drain_wait: 600, to_s: "payments")
    @backend = FakeBackend.new(hostnames: { "app-payments\\.2-123" => "1.1.1.2-aaaaaaaaaaaa", "app-payments\\.3-123" => "1.1.1.2-bbbbbbbbbbbb" })
    [ 2, 3 ].each do |replica|
      DASH.stubs(:app).with(role: @role, host: "1.1.1.2", replica: replica).returns(Dash::Commands::App.new(config, role: config.role(:payments), host: "1.1.1.2", replica: replica))
    end
  end

  test "reads the leaving containers' hostnames before the drain signal, and stops waiting once nothing is busy" do
    busy = FakeBusy.new(3, 1, 0)
    leave = leave(busy)
    leave.stubs(:monotonic).returns(0, 2, 4)
    leave.expects(:sleep).with(2).twice

    leave.send(:drain)

    first_signal = @backend.calls.index { |kind, command| kind == :execute && command.include?("docker kill --signal=TSTP") }
    last_capture = @backend.calls.rindex { |kind, _| kind == :capture }
    assert last_capture < first_signal, @backend.calls.inspect
    assert_equal [ [ "1.1.1.2-aaaaaaaaaaaa", "1.1.1.2-bbbbbbbbbbbb" ] ] * 3, busy.asked
  end

  test "busy already at nothing ends the drain without a wait" do
    leave = leave(FakeBusy.new(0))
    leave.stubs(:monotonic).returns(0)
    leave.expects(:sleep).never

    leave.send(:drain)
  end

  test "the drain never waits past drain.wait" do
    leave = leave(FakeBusy.new(5))
    leave.stubs(:monotonic).returns(0, 2, 599, 600)
    leave.expects(:sleep).with(2)
    leave.expects(:sleep).with(1)

    leave.send(:drain)
  end

  test "a busy count that cannot be read falls back to the rest of drain.wait" do
    leave = leave(FakeBusy.new(2, RuntimeError.new("Connection refused")))
    leave.stubs(:monotonic).returns(0, 2)
    leave.expects(:sleep).with(2)
    leave.expects(:sleep).with(598)

    leave.send(:drain)
    assert(@backend.calls.any? { |kind, message| kind == :info && message.include?("Connection refused") })
  end

  test "Sidekiq knowing no process in the leaving containers waits out the rest of drain.wait" do
    leave = leave(FakeBusy.new(nil))
    leave.stubs(:monotonic).returns(0, 0)
    leave.expects(:sleep).with(600)

    leave.send(:drain)
    assert(@backend.calls.any? { |kind, message| kind == :info && message.include?("Sidekiq reports no process") })
  end

  test "hostnames that cannot be read fall back to the full drain.wait" do
    @backend = FakeBackend.new(hostnames: { "app-payments\\.2-123" => SSHKit::Command::Failed.new("gone") })
    busy = FakeBusy.new(0)
    leave = leave(busy, leaving: { 2 => "123" })
    leave.expects(:sleep).with(600)

    leave.send(:drain)
    assert_empty busy.asked
  end

  test "a role without a Sidekiq signal waits drain.wait, and never reads a hostname" do
    leave = Dash::Cli::Scale::ReplicaLeave.new("1.1.1.2", @role, { 2 => "123" }, @backend, running: [ 1, 2 ], busy_reader: nil)
    leave.expects(:sleep).with(600)

    leave.send(:drain)
    assert_empty(@backend.calls.select { |kind, _| kind == :capture })
  end

  test "the busy reader is the role's Sidekiq signal; other sources and unsignalled roles have none" do
    assert_instance_of Dash::Autoscale::Signal::Sidekiq, Dash::Cli::Scale::ReplicaLeave.busy_reader_for(signalled("sidekiq").role(:payments))
    assert_nil Dash::Cli::Scale::ReplicaLeave.busy_reader_for(signalled("pgbus").role(:payments))
    assert_nil Dash::Cli::Scale::ReplicaLeave.busy_reader_for(signalled("sidekiq").role(:web))
  end

  private
    def leave(busy, leaving: { 2 => "123", 3 => "123" })
      Dash::Cli::Scale::ReplicaLeave.new("1.1.1.2", @role, leaving, @backend, running: [ 1, 2, 3 ], busy_reader: busy)
    end

    def config
      @config ||= Dash::Configuration.new({ service: "app", image: "dhh/app", registry: { "username" => "u", "password" => "p" },
        builder: { "arch" => "amd64" }, servers: { "web" => [ "1.1.1.1" ], "payments" => { "hosts" => [ "1.1.1.2" ], "cmd" => "sidekiq", "healthcheck" => false } } })
    end

    def signalled(source)
      Dash::Configuration.new({ service: "app", image: "dhh/app", registry: { "username" => "u", "password" => "p" }, builder: { "arch" => "amd64" },
        servers: { "web" => [ "1.1.1.1" ], "payments" => { "hosts" => [ "1.1.1.2" ], "cmd" => "sidekiq", "healthcheck" => false,
          "scale" => { "max" => 2, "signal" => { "source" => source, "queues" => [ "default" ] }, "up" => { "above" => 10 }, "down" => { "below" => 2 } } } },
        autoscale: { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } }, "redis" => { "url" => "redis://cache:6379" },
          "postgres" => { "url" => "postgres://db/app" } } })
    end
end
