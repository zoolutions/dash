require_relative "mcp_test_case"

# The autoscale tools stay within the server's --roles/--hosts ceiling, and never need the
# pool to decide whether a role is in scope.
class McpAutoscaleToolsTest < McpTestCase
  setup do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
  end

  test "explain answers pool_unreadable when the provider is down" do
    Dash::Autoscale::Provider::Upcloud.any_instance.stubs(:members).raises(Dash::Autoscale::ProviderError, "down")

    explain = call_json("autoscale_explain", { role: "payments" }, on: server(session(fixture: :deploy_with_scale_schedule, roles: [ "web", "payments" ])))

    assert_equal [ "pool_unreadable" ], explain.dig("decision", "reasons")
  end

  test "explain refuses a role outside --roles" do
    text, error = call_tool("autoscale_explain", { role: "reports" }, on: server(session(fixture: :deploy_with_scale_schedule, roles: [ "web", "payments" ])))

    assert error
    assert_match "reports is outside this server's --roles", text
  end

  test "decisions keep to --roles, with or without a role, filtered before the tail" do
    reads = []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).with { |*args| reads << args.join(" ") if args.join(" ").include?("tail -n"); true }.returns("")
    scoped = server(session(fixture: :deploy_with_scale_schedule, roles: [ "web", "payments" ]))

    call_json("autoscale_decisions", {}, on: scoped)
    assert_match %(grep -F -e '"role":"web"' -e '"role":"payments"'), reads.last
    assert call_tool("autoscale_decisions", { role: "reports" }, on: scoped).last
  end

  test "a --hosts ceiling alone still scopes roles, by their baseline hosts" do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(members: []))
    scoped = server(session(fixture: :deploy_with_scale_schedule, hosts: [ "1.1.1.1", "1.1.1.2" ]))

    text, error = call_tool("autoscale_decisions", { role: "reports" }, on: scoped)
    assert error
    assert_match "reports is outside this server's --roles and --hosts", text

    text, error = call_tool("autoscale_explain", { role: "payments" }, on: scoped)
    assert error
    assert_match "cannot be narrowed with --hosts", text
  end

  test "the state host must be within the --roles ceiling's hosts" do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(members: []))

    text, error = call_tool("controller_status", {}, on: server(session(fixture: :deploy_with_scale_schedule, roles: [ "payments" ])))

    assert error
    assert_match "The autoscale state lives on 1.1.1.1, outside this server's --hosts and --roles", text
  end
end
