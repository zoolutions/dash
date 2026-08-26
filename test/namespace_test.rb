require "test_helper"

# Stage 2 of the rename (issue #117): the gem's Ruby identity is Dash::, and
# the old Kamal:: namespace is gone — no compat alias. The remaining server
# artifacts (dash-proxy container, kamal network, KAMAL_* env) are stage 3c
# and unaffected; the run directory became .dash/ in 3b.
class NamespaceTest < ActiveSupport::TestCase
  test "the gem loads under the Dash namespace" do
    assert defined?(Dash::Cli::Main), "Dash::Cli::Main should be loadable"
    assert defined?(Dash::VERSION), "Dash::VERSION should be defined"
    assert_kind_of Dash::Commander, DASH
  end

  test "the Kamal namespace no longer exists" do
    assert_nil defined?(Kamal), "Kamal:: should be gone — stage 2 renamed the Ruby namespace"
    assert_nil defined?(KAMAL), "the KAMAL singleton is now DASH"
  end

  test "thor commands live in the dash namespace" do
    assert_equal "dash:cli:app", Dash::Cli::App.namespace
    assert_equal "dash:cli:proxy", Dash::Cli::Proxy.namespace
  end
end
