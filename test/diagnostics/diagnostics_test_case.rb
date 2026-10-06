require "test_helper"

class DiagnosticsTestCase < ActiveSupport::TestCase
  setup do
    ENV["VERSION"] = "999"
    Object.send(:remove_const, :DASH)
    Object.const_set(:DASH, Dash::Commander.new)
    Dash::Configuration::Proxy.any_instance.stubs(:load_balancing?).returns(false)
  end

  teardown do
    ENV.delete("VERSION")
  end

  private
    def configure(fixture)
      DASH.configure config_file: Pathname.new(File.expand_path("../fixtures/#{fixture}.yml", __dir__))
    end

    # Answers a capture on one host whose command contains `fragment`.
    def stub_capture(host, fragment, output)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?(fragment) }
        .returns(output)
    end

    def stub_unreachable(host, fragment)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| SSHKit::Backend.current.host.to_s == host && args.join(" ").include?(fragment) }
        .raises(Errno::ECONNREFUSED)
    end

    # One line of the app's `docker ps`: the container's JSON, a tab, then docker's own value
    # of its `role` label.
    def ps_line(name, id:, role:, state: "running", status: "Up 2 hours (healthy)", labels: "service=app,role=#{role},destination=")
      ps = { "ID" => id, "Names" => name, "Image" => "dhh/app:999", "State" => state, "Status" => status,
        "Labels" => labels, "CreatedAt" => "2026-10-05 10:00:00 +0000 UTC" }

      "#{ps.to_json}\t#{role.to_json}"
    end
end
