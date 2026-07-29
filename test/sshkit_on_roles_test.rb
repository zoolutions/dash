require "test_helper"

# Behaviour of the per-role runner options, as opposed to test/cli/app_test.rb which only
# asserts that the right options reach `on`. These run SSHKit's real runners against the
# printer backend.
class SshkitOnRolesTest < ActiveSupport::TestCase
  include SSHKit::DSL

  teardown do
    Thread.report_on_exception = true
  end

  test "a paced role stops booting its hosts at the first failure" do
    booted, role = [], role_with(%w[ 1.1.1.3 1.1.1.4 ], in: :sequence, wait: 0)

    Thread.report_on_exception = false

    assert_raises(SSHKit::Runner::ExecuteError) do
      stdouted do
        on_roles([ role ], hosts: role.hosts, rolling: true) do |host, _role|
          booted << host.to_s
          raise "boom"
        end
      end
    end

    assert_equal %w[ 1.1.1.3 ], booted
  end

  test "an unpaced role starts every host regardless" do
    booted, role = [], role_with(%w[ 1.1.1.3 1.1.1.4 ])

    Thread.report_on_exception = false

    assert_raises(SSHKit::Runner::ExecuteError) do
      stdouted do
        on_roles([ role ], hosts: role.hosts, rolling: true) do |host, _role|
          booted << host.to_s
          raise "boom"
        end
      end
    end

    assert_equal %w[ 1.1.1.3 1.1.1.4 ], booted.sort
  end

  test "pacing one role leaves its siblings booting in parallel" do
    paced = role_with(%w[ 1.1.1.3 1.1.1.4 ], in: :sequence, wait: 0)
    unpaced = role_with(%w[ 1.1.1.1 1.1.1.2 ])
    order = Queue.new

    stdouted do
      on_roles([ unpaced, paced ], hosts: paced.hosts + unpaced.hosts, rolling: true) do |host, _role|
        order << host.to_s
        sleep 0.05 if host.to_s == "1.1.1.3"
      end
    end

    booted = Array.new(order.size) { order.pop }

    # The paced role's second host waits out the first; the unpaced role never does.
    assert_equal 4, booted.size
    assert_operator booted.index("1.1.1.3"), :<, booted.index("1.1.1.4")
    assert_operator booted.index("1.1.1.2"), :<, booted.index("1.1.1.4")
  end

  # Only the two methods on_roles asks a role for.
  def role_with(hosts, **runner_options)
    stub(hosts: hosts, boot_runner_options: runner_options, to_s: hosts.first)
  end
end
