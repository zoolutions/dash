require "test_helper"

class AutoscaleProviderExecTest < ActiveSupport::TestCase
  LABELS = { "dash.service" => "app", "dash.destination" => "-", "dash.role" => "payments" }
  SCRIPTS = { members: "bin/pool-members", start: "bin/pool-start", stop: "bin/pool-stop", create: "bin/pool-create" }

  setup do
    @provider = Dash::Autoscale::Provider::Exec.new(scripts: ->(action) { SCRIPTS[action] })
  end

  test "members parses one JSON object per line and keeps the role's" do
    expect_script "bin/pool-members", env: { "DASH_SERVICE" => "app", "DASH_DESTINATION" => "-", "DASH_ROLE" => "payments", "KAMAL_ROLE" => "payments" },
      output: <<~JSON
        {"id":"m1","host":"10.0.0.22","role":"payments","state":"started"}

        {"id":"m2","host":"10.0.0.23","role":"payments","state":"stopped"}
        {"id":"w1","host":"10.0.0.40","role":"web","state":"started"}
      JSON

    members = @provider.members(labels: LABELS, address: "private")

    assert_equal [ [ "m1", "10.0.0.22", "started" ], [ "m2", "10.0.0.23", "stopped" ] ], members.map { |member| [ member.id, member.host, member.state ] }
    assert_equal LABELS, members.first.labels
  end

  test "start and stop hand the script the member" do
    member = Dash::Autoscale::Member.new(id: "m1", host: "10.0.0.22", role: "payments", state: "stopped", labels: LABELS)

    expect_script "bin/pool-start", env: { "DASH_MEMBER_ID" => "m1", "DASH_HOST" => "10.0.0.22", "DASH_ROLE" => "payments" }
    @provider.start(member)

    expect_script "bin/pool-stop", env: { "DASH_MEMBER_ID" => "m1", "DASH_STOP_TIMEOUT" => "40" }
    @provider.stop(member, timeout: 40)
  end

  test "create prints the new member" do
    expect_script "bin/pool-create", output: %({"id":"m9","host":"10.0.0.30","state":"started"}\n)

    member = @provider.create(labels: LABELS, template: nil, address: "private")

    assert_equal [ "m9", "10.0.0.30", "payments" ], [ member.id, member.host, member.role ]
  end

  test "a missing script fails naming the key" do
    member = Dash::Autoscale::Member.new(id: "m1", role: "payments", labels: LABELS)

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.destroy(member) }
    assert_equal "exec: no destroy script, set autoscale/provider/exec/destroy", error.message
  end

  test "a failing script fails with its stderr" do
    expect_script "bin/pool-members", stderr: "token expired\n", success: false, exitstatus: 3

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_equal "exec: bin/pool-members exited 3: token expired", error.message
  end

  test "output that is not JSON, or an unknown state, is an error" do
    expect_script "bin/pool-members", output: "m1 10.0.0.22 started\n"
    assert_raises_message(/exec: expected one JSON object per line, got "m1 10.0.0.22 started"/) { @provider.members(labels: LABELS, address: "private") }

    expect_script "bin/pool-members", output: %({"id":"m1","host":"h","role":"payments","state":"running"}\n)
    assert_raises_message(/exec: member m1 has state "running"/) { @provider.members(labels: LABELS, address: "private") }
  end

  test "a member without an id or a host, or a row that is not an object, is an error" do
    expect_script "bin/pool-members", output: %({"id":"m1","state":"started","role":"payments"}\n)
    assert_raises_message(/exec: a member needs an id and a host, got/) { @provider.members(labels: LABELS, address: "private") }

    expect_script "bin/pool-members", output: %({"host":"10.0.0.22","state":"started","role":"payments"}\n)
    assert_raises_message(/exec: a member needs an id and a host, got/) { @provider.members(labels: LABELS, address: "private") }

    expect_script "bin/pool-members", output: "[]\nnull\n"
    assert_raises_message(/exec: expected one JSON object per line, got "\[\]"/) { @provider.members(labels: LABELS, address: "private") }
  end

  test "only the last line of a failing script's stderr is kept" do
    expect_script "bin/pool-members", stderr: "debug: token=abc123\n#{"x" * 300}\n", success: false, exitstatus: 1

    error = assert_raises(Dash::Autoscale::ProviderError) { @provider.members(labels: LABELS, address: "private") }
    assert_no_match(/token=abc123/, error.message)
    assert_operator error.message.length, :<, 250
  end

  test "state comes from the members script" do
    member = Dash::Autoscale::Member.new(id: "m2", role: "payments", labels: LABELS)
    expect_script "bin/pool-members", output: %({"id":"m2","host":"h","role":"payments","state":"maintenance"}\n)

    assert_equal "maintenance", @provider.state(member)
  end

  private
    def expect_script(script, env: {}, output: "", stderr: "", success: true, exitstatus: 0)
      status = stub(success?: success, exitstatus: exitstatus)
      Open3.expects(:capture3).with { |given_env, given_script| given_script == script && env.all? { |key, value| given_env[key] == value } }
        .returns([ output, stderr, status ])
    end

    def assert_raises_message(pattern, &block)
      error = assert_raises(Dash::Autoscale::ProviderError, &block)
      assert_match pattern, error.message
    end
end
