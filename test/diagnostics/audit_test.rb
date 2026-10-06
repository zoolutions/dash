require_relative "diagnostics_test_case"

class DiagnosticsAuditTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "parses each audit line into when, who, tags and message" do
    stub_capture "1.1.1.1", "tail -n 20", "[2026-10-05T10:00:00Z] [jane@example.com] [web] Booted app version 999\nnot an audit line\n"

    entries = Dash::Diagnostics::Audit.new(hosts: [ "1.1.1.1" ], lines: 20).to_h[:hosts].first[:entries]

    assert_equal({ recorded_at: "2026-10-05T10:00:00Z", performer: "jane@example.com", tags: [ "web" ], message: "Booted app version 999" }, entries.first)
    assert_equal({ message: "not an audit line" }, entries.last)
  end

  test "reads at most 500 lines per host" do
    assert_raises(ArgumentError) { Dash::Diagnostics::Audit.new(lines: 501) }
    assert_raises(ArgumentError) { Dash::Diagnostics::Audit.new(lines: 0) }
    assert_raises(ArgumentError) { Dash::Diagnostics::Audit.new(lines: "5; rm -rf /") }
  end
end
