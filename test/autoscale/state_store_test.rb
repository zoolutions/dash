require "test_helper"

class AutoscaleStateStoreTest < ActiveSupport::TestCase
  DIR = ".dash/apps/app/autoscale"

  setup do
    @backend = mock("backend")
    @store = Dash::Autoscale::StateStore.new(@backend, config: config)
  end

  test "lives on the primary role's first baseline host, never on a member" do
    Dash::Autoscale::Pool.any_instance.expects(:members_for).never

    assert_equal "1.1.1.1", Dash::Autoscale::StateStore.host(config)
  end

  test "a missing file reads as empty" do
    @backend.stubs(:capture).returns("")

    assert_equal({}, @store.heartbeat)
    assert_equal({}, @store.state)
    assert_equal({}, @store.pauses)
    assert_equal [], @store.decisions(lines: 50)
  end

  test "reads the heartbeat and the state" do
    stub_capture "cat #{DIR}/heartbeat.json", %({"controller_id":"abc","pid":42})
    stub_capture "cat #{DIR}/state.json", %({"roles":{"payments":{"last_scale_out_at":"2026-10-14T22:00:00Z"}}})

    assert_equal({ "controller_id" => "abc", "pid" => 42 }, @store.heartbeat)
    assert_equal "2026-10-14T22:00:00Z", @store.state.dig("roles", "payments", "last_scale_out_at")
  end

  test "a malformed file reads as empty and warns once" do
    @backend.stubs(:capture).returns("{not json")

    _, err = capture_io do
      assert_equal({}, @store.heartbeat)
      assert_equal({}, @store.heartbeat)
    end
    assert_equal 1, err.scan("heartbeat.json").size, err
    assert_match "#{DIR}/heartbeat.json on 1.1.1.1 is not valid JSON, treating it as empty", err
  end

  test "a file holding JSON that is not an object reads as empty" do
    @backend.stubs(:capture).returns("[1,2]")

    capture_io { assert_equal({}, @store.state) }
  end

  test "writes the heartbeat and the state as JSON" do
    expect_written("heartbeat.json", { "controller_id" => "abc", "last_tick_at" => "2026-10-14T22:00:00Z" })
    expect_written("state.json", { "roles" => {} })

    @store.write_heartbeat("controller_id" => "abc", "last_tick_at" => Time.utc(2026, 10, 14, 22))
    @store.write_state("roles" => {})
  end

  test "says whether it wrote the heartbeat, false only when another controller holds it" do
    @backend.stubs(:capture).with { |*args| args.join(" ").include?("grep -qF") }.returns("held\n").then.returns("taken\n")

    assert @store.write_heartbeat_if_held("ab12", "controller_id" => "ab12")
    assert_not @store.write_heartbeat_if_held("ab12", "controller_id" => "ab12")
  end

  test "reads no decisions for an empty set of roles, without asking the host" do
    @backend.expects(:capture).never

    assert_equal [], @store.decisions(lines: 50, roles: [])
  end

  test "remembers which file was malformed" do
    @backend.stubs(:capture).returns("{not json")

    capture_io { @store.heartbeat }
    assert @store.malformed?("heartbeat.json")
    assert_not @store.malformed?("state.json")
  end

  test "creates its directory" do
    @backend.expects(:execute).with(:mkdir, "-p", "#{DIR}/pause")

    @store.ensure_directory
  end

  test "appends decisions one per line, and reads the last ones back, skipping lines that do not parse" do
    decision = Dash::Autoscale::Decision.new(role: "payments", action: "hold", from: 1, to: 1, reasons: [ "at_target" ], at: Time.utc(2026, 10, 6))
    @backend.expects(:execute).with do |*args|
      encoded = args.join(" ")[/echo "([^"]+)"/, 1]
      lines = Base64.strict_decode64(encoded).lines
      lines.size == 2 && JSON.parse(lines.first) == JSON.parse(JSON.generate(decision.to_h)) && JSON.parse(lines.last) == { "role" => "web" }
    end
    @store.append_decisions([ decision, { role: "web" } ])

    stub_capture "tail -n 3 #{DIR}/decisions.jsonl", %({"role":"payments"}\nnot json\n{"role":"web"}\n)
    capture_io { assert_equal [ { "role" => "payments" }, { "role" => "web" } ], @store.decisions(lines: 3) }
  end

  test "nothing to append is no command" do
    @backend.expects(:execute).never

    @store.append_decisions([])
  end

  test "counts and trims the decision log" do
    stub_capture "wc -l < #{DIR}/decisions.jsonl", "  10042\n"
    @backend.expects(:execute).with { |*args| args.join(" ").start_with?("tail -n 5000 #{DIR}/decisions.jsonl > ") }

    assert_equal 10_042, @store.decision_count
    @store.trim_decisions(keep: 5000)
  end

  test "pauses by role" do
    stub_capture "grep -H", <<~OUT
      #{DIR}/pause/payments.json:{"until":"2026-10-06T14:00:00Z","by":"ops"}
      #{DIR}/pause/web.json:{"until":"indefinite","by":"ops"}
      #{DIR}/pause/web.json.tmp:{"until":"indefinite","by":"ops"}
      #{DIR}/pause/api.v2.json:{"until":"indefinite","by":"ops"}
    OUT

    assert_equal({ "payments" => { "until" => "2026-10-06T14:00:00Z", "by" => "ops" }, "web" => { "until" => "indefinite", "by" => "ops" },
      "api.v2" => { "until" => "indefinite", "by" => "ops" } }, @store.pauses)
  end

  test "writes and removes a pause" do
    expect_written("pause/payments.json", { "until" => "indefinite", "by" => "ops" })
    @backend.expects(:execute).with(:rm, "-f", "#{DIR}/pause/payments.json")

    @store.write_pause("payments", "until" => "indefinite", "by" => "ops")
    @store.remove_pause("payments")
  end

  private
    def config
      @config ||= Dash::Configuration.new({
        service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, builder: { "arch" => "amd64" },
        servers: { "web" => [ "1.1.1.1", "1.1.1.2" ], "payments" => { "hosts" => [ "1.1.1.3" ], "cmd" => "sidekiq", "healthcheck" => false, "scale" => { "max" => 2 } } },
        autoscale: { "provider" => { "upcloud" => { "username" => "u", "password" => "p" } } }
      })
    end

    def stub_capture(prefix, output)
      @backend.stubs(:capture).with { |*args| args.join(" ").start_with?(prefix) }.returns(output)
    end

    def expect_written(file, data)
      @backend.expects(:execute).with do |*args|
        command = args.reject { |arg| arg.is_a?(Hash) }.join(" ")
        encoded = command[/echo "([^"]+)"/, 1]
        command.end_with?("mv #{DIR}/#{file}.tmp #{DIR}/#{file}") && JSON.parse(Base64.strict_decode64(encoded)) == data
      end
    end
end
