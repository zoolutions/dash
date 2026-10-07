require_relative "mcp_test_case"

# The read-only contract as a test, not a comment: every command any tool sends to a host
# must match a known read-only shape. A new tool, or a diagnostic that grows a new
# command, fails here until the shape is reviewed and added.
class McpReadOnlyTest < McpTestCase
  READ_ONLY_CAPTURES = [
    /\Adocker ps --all --filter label=service=\S+ --format '\{\{json \.\}\}'\z/,                                     # accessory containers
    /\Adocker logs \S+ +( --since [\w:.+-]+ +)? --tail \d+ --timestamps 2>&1\z/,                                       # accessory logs
    /\Adocker container ls --all( --filter \S+)+ --format '\{\{json \.\}\}\{\{"\\t"\}\}\{\{json \(\.Label "role"\)\}\}'\z/,                        # containers
    /\Adocker exec \S+ dash-proxy list --json\z/,                                                         # proxy and load balancer routes
    %r{\Astat \S+ > /dev/null && cat \S+ \| base64 -d\z},                                                 # deploy lock
    /\Atail -n \d+ \S+\z/,                                                                                # audit log
    /\A(echo --dash-replica-\h+-- ; sh -c 'docker ps [^;]*; docker ps [^']*' \| head -1 \| xargs docker logs --timestamps( --since [\w:.+-]+)? --tail \d+ 2>&1( ; )?)+\z/, # logs, every slot
    /\Adocker inspect \S+ --format '\{\{\.Config\.Image\}\}' \| awk -F: '\{print \$NF\}'\z/,              # doctor: proxy version
    /\Adocker inspect \S+ --format '\{\{range \.Mounts\}\}\{\{println \.Destination\}\}\{\{end\}\}'\z/,   # doctor: proxy socket
    /\Ass -ltnH sport = :\d+\z/,                                                                          # doctor: ports
    /\Adocker ps( --filter \S+)+ --format "\{\{\.Names\}\}\\t\{\{\.Status\}\}"\z/,                          # scale status
    /\Adocker ps( --filter \S+)+ --format '\{\{json \.\}\}(\{\{"\\t"\}\}\{\{json \(\.Label "role"\)\}\})?' \|\| echo --unreadable-- ; echo --%-- ; docker ps --quiet( --filter \S+)+ \| xargs -r docker stats --no-stream --format '\{\{json \.\}\}' \|\| echo --stats-unreadable--\z/, # container stats
    %r{\Acat \S+/autoscale/(heartbeat|state)\.json 2> /dev/null \|\| echo ""\z},                                      # autoscale state
    %r{\Agrep -H "" \S+/autoscale/pause/\* 2> /dev/null \|\| true\z},                                             # autoscale pauses
    %r{\A(grep -F '"role":"[\w.-]+"' \S+/autoscale/decisions\.jsonl 2> /dev/null \| )?tail -n \d+( \S+/autoscale/decisions\.jsonl 2> /dev/null)? \|\| true\z}, # autoscale decisions
    %r{\Acat /proc/loadavg ; echo --%-- ; getconf _NPROCESSORS_ONLN ; echo --%-- ; grep -E '\^\(MemTotal\|MemAvailable\|SwapTotal\|SwapFree\):' /proc/meminfo ; echo --%-- ; df -Pk / ; echo --%-- ; df -Pk "\$\(docker info --format '\{\{\.DockerRootDir\}\}'\)" ; echo --%-- ; cat /proc/uptime\z} # host stats
  ].freeze

  # Only the doctor executes, and only these: it checks exit statuses, not output.
  DOCTOR_EXECUTES = [ /\Atrue\z/, /\Adocker version\z/, /\Adocker manifest inspect \S+\z/ ].freeze

  setup do
    Resolv.stubs(:getaddresses).returns([ "1.1.1.1" ])
    Dash::Diagnostics::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate).returns(nil)
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    @captures, @executes = [], []
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| @captures << command(args); true }.returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture).with { |*args| @captures << command(args); true }.returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:execute).with { |*args| @executes << command(args); true }.returns(true)
  end

  test "the autoscale tools only read the controller's state" do
    Dash::Autoscale::Provider.stubs(:for).returns(stub(members: []))
    server = self.server(session(fixture: :deploy_with_scale_schedule))

    { "autoscale_explain" => { role: "payments" }, "autoscale_decisions" => { role: "payments", lines: 5 }, "controller_status" => {} }.each do |name, arguments|
      @captures.clear
      call_json(name, arguments, on: server)

      assert @captures.any? { |command| command.include?("/autoscale/") }, "#{name} did not read the controller's state"
      @captures.each { |command| assert READ_ONLY_CAPTURES.any? { |shape| shape.match?(command) }, "#{name} captured a command that is not a known read: #{command}" }
    end
    assert_empty @executes
  end

  test "every tool only reads" do
    server = self.server(session(fixture: :deploy_with_accessories, allow_logs: true))
    arguments = { "logs" => { since: "15m", grep: "x" }, "audit" => { lines: 10 } }
    call_tool("logs", { accessory: "mysql", since: "1h" }, on: server)
    @captures.each { |command| assert READ_ONLY_CAPTURES.any? { |shape| shape.match?(command) }, "accessory logs captured: #{command}" }
    assert @captures.any? { |command| command.start_with?("docker logs app-mysql") }, "the accessory's logs were not read"
    assert_empty @executes, "accessory logs executed commands"

    Dash::Mcp::Server::TOOLS.map(&:tool_name).each do |name|
      @captures.clear
      @executes.clear
      call_tool(name, arguments.fetch(name, {}), on: server)

      @captures.each { |command| assert READ_ONLY_CAPTURES.any? { |shape| shape.match?(command) }, "#{name} captured a command that is not a known read: #{command}" }

      if name == "doctor"
        @executes.each { |command| assert DOCTOR_EXECUTES.any? { |shape| shape.match?(command) }, "doctor executed: #{command}" }
      else
        assert_empty @executes, "#{name} executed commands"
      end
    end
  end

  test "the allowlist covers the load balancer, the logs and the doctor" do
    server = self.server(session(fixture: :deploy_with_loadbalancer, allow_logs: true))
    %w[ proxy_services logs doctor ].each { |name| call_tool(name, {}, on: server) }

    assert @captures.any? { |command| command.include?(DASH.loadbalancer.list(json: true).join(" ")) }, "the load balancer was not asked"
    assert @captures.any? { |command| command.include?("xargs docker logs") }, "no logs were read"
    assert @executes.include?("docker version"), "the doctor did not run"
    assert @executes.none? { |command| command.include?("login") }, "the doctor logged in to the registry"
  end

  test "the doctor says it left the registry check out" do
    doctor = call_json("doctor")

    assert_equal [ "registry" ], doctor["skipped"].map { |skipped| skipped["check"] }
    assert_empty doctor["results"].select { |result| result["check"] == "registry" }
  end

  private
    def command(args)
      args.reject { |arg| arg.is_a?(Hash) }.join(" ")
    end
end
