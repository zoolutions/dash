require_relative "diagnostics_test_case"

class DiagnosticsConfigTest < DiagnosticsTestCase
  test "describes the topology: roles to hosts, proxied roles, proxies and the load balancer" do
    configure :deploy_with_roles

    snapshot = Dash::Diagnostics::Config.new.to_h

    assert_equal "app", snapshot[:service]
    assert_equal({ name: "web", hosts: [ "1.1.1.1", "1.1.1.2" ], primary: true, proxied: true, replicas: { min: 1, max: 1 } }, snapshot[:roles].first)
    assert_equal({ name: "workers", hosts: [ "1.1.1.3", "1.1.1.4" ], primary: false, proxied: false, replicas: { min: 1, max: 1 } }, snapshot[:roles].last)
    assert_equal({ hosts: [ "1.1.1.1", "1.1.1.2" ], loadbalancer: nil }, snapshot[:proxy])
  end

  test "is JSON-safe even with an SSH jump host and symbols in the config" do
    configure :deploy_with_ssh_proxy

    snapshot = Dash::Diagnostics::Config.new.to_h

    assert_equal JSON.parse(snapshot.to_json), snapshot.deep_stringify_keys
    assert_equal "jump root@bastion.example.com", snapshot.dig(:config, :ssh_options, :proxy)
  end
end
