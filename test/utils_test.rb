require "test_helper"

class UtilsTest < ActiveSupport::TestCase
  test "argumentize" do
    assert_equal [ "--label", "foo=\"\\`bar\\`\"", "--label", "baz=\"qux\"", "--label", :quux, "--label", "quuz=false" ], \
      Dash::Utils.argumentize("--label", { foo: "`bar`", baz: "qux", quux: nil, quuz: false })
  end

  test "argumentize with redacted" do
    assert_kind_of SSHKit::Redaction, \
      Dash::Utils.argumentize("--label", { foo: "bar" }, sensitive: true).last
  end

  test "optionize" do
    assert_equal [ "--foo", "\"bar\"", "--baz", "\"qux\"", "--quux" ], \
      Dash::Utils.optionize({ foo: "bar", baz: "qux", quux: true })
  end

  test "optionize with" do
    assert_equal [ "--foo=\"bar\"", "--baz=\"qux\"", "--quux" ], \
      Dash::Utils.optionize({ foo: "bar", baz: "qux", quux: true }, with: "=")
  end

  test "no redaction from #to_s" do
    assert_equal "secret", Dash::Utils.sensitive("secret").to_s
  end

  test "redact from #inspect" do
    assert_equal "[REDACTED]".inspect, Dash::Utils.sensitive("secret").inspect
  end

  test "redact from SSHKit output" do
    assert_kind_of SSHKit::Redaction, Dash::Utils.sensitive("secret")
  end

  test "redact from YAML output" do
    assert_equal "--- ! '[REDACTED]'\n", YAML.dump(Dash::Utils.sensitive("secret"))
  end

  test "escape_shell_value" do
    assert_equal "\"foo\"", Dash::Utils.escape_shell_value("foo")
    assert_equal "\"\\`foo\\`\"", Dash::Utils.escape_shell_value("`foo`")

    assert_equal "\"${PWD}\"", Dash::Utils.escape_shell_value("${PWD}")
    assert_equal "\"${cat /etc/hostname}\"", Dash::Utils.escape_shell_value("${cat /etc/hostname}")
    assert_equal "\"\\${PWD]\"", Dash::Utils.escape_shell_value("${PWD]")
    assert_equal "\"\\$(PWD)\"", Dash::Utils.escape_shell_value("$(PWD)")
    assert_equal "\"\\$PWD\"", Dash::Utils.escape_shell_value("$PWD")

    assert_equal "\"^(https?://)www.example.com/(.*)\\$\"",
      Dash::Utils.escape_shell_value("^(https?://)www.example.com/(.*)$")
    assert_equal "\"https://example.com/\\$2\"",
      Dash::Utils.escape_shell_value("https://example.com/$2")
  end

  test "escape_shell_value leaves ${...} to the deploy host shell but escapes the bare form" do
    # ${...} survives escaping, so it is expanded by the deploy host's shell at docker run
    # time and can never see a role env var. The bare form is escaped and expands in the
    # container. Dash::Configuration::Validator rejects the braced form in health options.
    assert_equal "\"${HEALTH_PORT}\"", Dash::Utils.escape_shell_value("${HEALTH_PORT}")
    assert_equal "\"\\$HEALTH_PORT\"", Dash::Utils.escape_shell_value("$HEALTH_PORT")
  end

  test "seconds_duration renders plain numbers as Go seconds" do
    assert_equal "30s", Dash::Utils.seconds_duration(30)
    assert_equal "30s", Dash::Utils.seconds_duration("30")
    assert_equal "1.5s", Dash::Utils.seconds_duration(1.5)
    assert_equal "-1s", Dash::Utils.seconds_duration(-1)
  end

  # Zero disables a timeout, so it is a value rather than an absence.
  test "seconds_duration keeps zero and drops only nil" do
    assert_equal "0s", Dash::Utils.seconds_duration(0)
    assert_nil Dash::Utils.seconds_duration(nil)
  end

  # Appending "s" to a value that already carries a unit changes its meaning:
  # "5m" would become "5ms", which Go accepts as five milliseconds.
  test "seconds_duration passes a value that already carries a unit through untouched" do
    assert_equal "5m", Dash::Utils.seconds_duration("5m")
    assert_equal "1h30m", Dash::Utils.seconds_duration("1h30m")
    assert_equal "500ms", Dash::Utils.seconds_duration("500ms")
    assert_equal "-1s", Dash::Utils.seconds_duration("-1s")
  end
end
