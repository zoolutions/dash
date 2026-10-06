require_relative "diagnostics_test_case"

class DiagnosticsProxyServicesTest < DiagnosticsTestCase
  test "lists this deploy's services per proxy host, and nobody else's" do
    configure :deploy_with_roles
    list = { services: { "app-web" => { host: "app.example.com", targets: [ "aaa:80" ], state: "running" },
                         "other-app-web" => { host: "other.example.com", targets: [ "zzz:80" ] } } }.to_json
    stub_capture "1.1.1.1", "list --json", list
    stub_unreachable "1.1.1.2", "list --json"

    snapshot = Dash::Diagnostics::ProxyServices.new.to_h

    assert_equal({ host: "1.1.1.1", services: { "app-web" => { "host" => "app.example.com", "targets" => [ "aaa:80" ], "state" => "running" } } }, snapshot[:hosts].first)
    assert_equal "1.1.1.2", snapshot[:hosts].last[:host]
    assert_match "ECONNREFUSED", snapshot[:hosts].last[:error]
    assert_nil snapshot[:loadbalancer]
  end

  test "adds the load balancer's routes when load balancing is on" do
    configure :deploy_with_loadbalancer
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    lb_host = DASH.config.proxy.effective_loadbalancer

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns({ services: {} }.to_json)
    stub_capture lb_host, DASH.loadbalancer.list(json: true).join(" "),
      { services: { "app" => { targets: [ "1.1.1.1:80", "1.1.1.2:80" ] }, "other" => {} } }.to_json

    loadbalancer = Dash::Diagnostics::ProxyServices.new.to_h[:loadbalancer]

    assert_equal lb_host, loadbalancer[:host]
    assert_equal({ "app" => { "targets" => [ "1.1.1.1:80", "1.1.1.2:80" ] } }, loadbalancer[:services])
  end
end
