require "test_helper"

class AutoscaleTunnelTest < ActiveSupport::TestCase
  class FakeForward
    attr_reader :forwards, :cancelled

    def initialize
      @forwards, @cancelled = [], []
    end

    def local(*args)
      @forwards << args
      54_321
    end

    def cancel_local(port, _bind_address = nil)
      @cancelled << port
    end
  end

  class FakeSession
    attr_reader :forward, :closed, :loops

    def initialize
      @forward = FakeForward.new
      @loops = 0
      @closed = false
    end

    def loop(_wait)
      while yield
        @loops += 1
        Kernel.sleep 0.01
      end
    end

    def close
      @closed = true
    end
  end

  test "opens a dedicated SSH session through the via host and forwards an ephemeral local port to the target" do
    session = FakeSession.new
    started = nil
    tunnel = Dash::Autoscale::Tunnel.new("10.0.0.31", "cache.internal", 6379, user: "deploy", ssh_options: { port: 22, keepalive: true },
      starter: ->(host, user, **options) { started = [ host, user, options ]; session })

    assert_equal [ "10.0.0.31", "deploy", { port: 22, keepalive: true } ], started
    assert_equal [ [ "127.0.0.1", 0, "cache.internal", 6379 ] ], session.forward.forwards
    assert_equal 54_321, tunnel.port
    assert_equal "127.0.0.1", tunnel.address

    wait_for { session.loops.positive? }
    tunnel.close

    assert session.closed
    assert_equal [ 54_321 ], session.forward.cancelled
    assert_not tunnel.alive?
  end

  test "open takes the SSH user and options from the configuration" do
    ssh = stub(user: "deploy", options: { user: "deploy", port: 2222, keepalive: true })
    Dash::Autoscale::Tunnel.expects(:new).with("10.0.0.31", "db.internal", 5432, user: "deploy", ssh_options: { port: 2222, keepalive: true }).returns(:tunnel)

    assert_equal :tunnel, Dash::Autoscale::Tunnel.open("10.0.0.31", "db.internal", 5432, ssh: ssh)
  end

  private
    def wait_for
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      Kernel.sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
end
