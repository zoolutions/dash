require_relative "diagnostics_test_case"

class DiagnosticsLockTest < DiagnosticsTestCase
  setup do
    configure :deploy_with_roles
  end

  test "reports who holds the lock, since when and why" do
    stub_capture "1.1.1.1", "lock-app", "Locked by: Jane Doe at 2026-10-05T10:00:00Z\nVersion: 999\nMessage: Migrating: step 2\n"

    assert_equal({ host: "1.1.1.1", held: true, locked_by: "Jane Doe", locked_at: "2026-10-05T10:00:00Z", version: "999", message: "Migrating: step 2" },
      Dash::Diagnostics::Lock.new.to_h[:lock])
  end

  test "an absent lock is not held" do
    stub_capture "1.1.1.1", "lock-app", ""

    assert_equal({ host: "1.1.1.1", held: false }, Dash::Diagnostics::Lock.new.to_h[:lock])
  end

  test "an unreachable primary is an error, not an answer" do
    stub_unreachable "1.1.1.1", "lock-app"

    assert_match "ECONNREFUSED", Dash::Diagnostics::Lock.new.to_h[:lock][:error]
  end
end
