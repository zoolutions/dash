require "test_helper"

class CommandsAutoscaleTest < ActiveSupport::TestCase
  DIR = ".dash/apps/app/autoscale"

  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ],
      builder: { "arch" => "amd64" }
    }
  end

  test "the directory, with its pause directory" do
    assert_equal "mkdir -p #{DIR}/pause", command.ensure_directory.join(" ")
  end

  test "under the destination's app directory" do
    assert_equal "mkdir -p .dash/apps/app-staging/autoscale/pause", Dash::Commands::Autoscale.new(Dash::Configuration.new(@config, destination: "staging")).ensure_directory.join(" ")
  end

  test "reads a missing file as nothing" do
    assert_equal "cat #{DIR}/heartbeat.json 2> /dev/null || echo \"\"", command.read_heartbeat.join(" ")
    assert_equal "cat #{DIR}/state.json 2> /dev/null || echo \"\"", command.read_state.join(" ")
  end

  test "writes JSON through base64, to a temporary file moved into place" do
    json = %({"pid":1,"note":"it's \\"quoted\\" $HOME `x`"})
    written = command.write_heartbeat(json).join(" ")
    encoded = written[/echo "([^"]+)"/, 1]

    assert_equal "echo \"#{encoded}\" | base64 -d > #{DIR}/heartbeat.json.tmp && mv #{DIR}/heartbeat.json.tmp #{DIR}/heartbeat.json", written
    assert_equal json, Base64.strict_decode64(encoded)
    assert_match "> #{DIR}/state.json.tmp && mv #{DIR}/state.json.tmp #{DIR}/state.json", command.write_state("{}").join(" ")
  end

  test "appends decision lines through base64, one JSON object per line" do
    written = command.append_decisions([ %({"role":"payments"}), %({"role":"web"}) ]).join(" ")
    encoded = written[/echo "([^"]+)"/, 1]

    assert_equal "echo \"#{encoded}\" | base64 -d >> #{DIR}/decisions.jsonl", written
    assert_equal %({"role":"payments"}\n{"role":"web"}\n), Base64.strict_decode64(encoded)
  end

  test "reads the last decision lines, nothing when there is no log" do
    assert_equal "tail -n 50 #{DIR}/decisions.jsonl 2> /dev/null || true", command.read_decisions(lines: 50).join(" ")
    assert_raises(ArgumentError) { command.read_decisions(lines: "50; rm -rf /") }
  end

  test "writes the heartbeat unless it names another controller, in one command" do
    assert_equal %(grep -qF '"controller_id":"' #{DIR}/heartbeat.json 2> /dev/null && ! grep -qF '"controller_id":"ab12"' #{DIR}/heartbeat.json && echo taken || ) +
      %(( echo "e30=" | base64 -d > #{DIR}/heartbeat.json.tmp && mv #{DIR}/heartbeat.json.tmp #{DIR}/heartbeat.json && echo held )),
      command.write_heartbeat_if_held("ab12", "{}").join(" ")
    assert_raises(ArgumentError) { command.write_heartbeat_if_held("x'; rm -rf /", "{}") }
  end

  test "reads the last decision lines of some roles, filtered before the tail" do
    assert_equal %(grep -F -e '"role":"payments"' #{DIR}/decisions.jsonl 2> /dev/null | tail -n 20 || true), command.read_decisions(lines: 20, roles: [ "payments" ]).join(" ")
    assert_equal %(grep -F -e '"role":"payments"' -e '"role":"web"' #{DIR}/decisions.jsonl 2> /dev/null | tail -n 20 || true),
      command.read_decisions(lines: 20, roles: [ "payments", "web" ]).join(" ")
    assert_raises(ArgumentError) { command.read_decisions(lines: 20, roles: [ "x'; rm -rf /" ]) }
  end

  test "counts and trims the decision log" do
    assert_equal "wc -l < #{DIR}/decisions.jsonl 2> /dev/null || echo 0", command.count_decisions.join(" ")
    assert_equal "tail -n 5000 #{DIR}/decisions.jsonl > #{DIR}/decisions.jsonl.tmp && mv #{DIR}/decisions.jsonl.tmp #{DIR}/decisions.jsonl",
      command.trim_decisions(keep: 5000).join(" ")
  end

  test "pauses are one file per role" do
    assert_match "| base64 -d > #{DIR}/pause/payments.json.tmp && mv #{DIR}/pause/payments.json.tmp #{DIR}/pause/payments.json", command.write_pause("payments", "{}").join(" ")
    assert_equal "rm -f #{DIR}/pause/payments.json", command.remove_pause("payments").join(" ")
    assert_equal "rm -f #{DIR}/pause/api.v2.json", command.remove_pause("api.v2").join(" ")
    assert_equal "grep -H \"\" #{DIR}/pause/* 2> /dev/null || true", command.read_pauses.join(" ")
  end

  test "a role name that is not a plain word never reaches a path" do
    [ "../web", ".hidden", "pay ments", "a;b", "a/b", "" ].each do |name|
      [ -> { command.write_pause(name, "{}") }, -> { command.remove_pause(name) } ].each do |call|
        error = assert_raises(ArgumentError, &call)
        assert_equal "#{name.inspect} is not a role name dash can keep autoscale state for", error.message
      end
    end
  end

  private
    def command
      Dash::Commands::Autoscale.new(Dash::Configuration.new(@config))
    end
end
