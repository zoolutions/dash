require "test_helper"

class ConfigurationProxyTrafficTest < ActiveSupport::TestCase
  setup do
    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  test "no traffic keys leave the deploy command unchanged" do
    options = deploy_options({})

    # log-request-header is always emitted; everything else in this group is not.
    assert_empty options.keys.grep(/(set|add|remove)-(request|response)-header/)
    assert_empty options.keys.grep(/redirect|rewrite|canonical|cookie|intercept/)
  end

  # Headers

  test "header rules become name-colon-value flags" do
    options = deploy_options "headers" => {
      "request" => { "set" => { "X-Forwarded-Host" => "app.example.com" }, "add" => { "X-Request-Source" => "kamal" }, "remove" => [ "X-Internal-Token" ] },
      "response" => { "set" => { "Strict-Transport-Security" => "max-age=31536000" }, "remove" => [ "Server" ] }
    }

    assert_equal [ "X-Forwarded-Host: app.example.com" ], options[:"set-request-header"]
    assert_equal [ "X-Request-Source: kamal" ], options[:"add-request-header"]
    assert_equal [ "X-Internal-Token" ], options[:"remove-request-header"]
    assert_equal [ "Strict-Transport-Security: max-age=31536000" ], options[:"set-response-header"]
    assert_equal [ "Server" ], options[:"remove-response-header"]
    assert_not options.key?(:"add-response-header")
  end

  # AC1: a header value is exactly the kind of field nobody thinks of as
  # injection surface.
  test "header values with spaces, quotes and dollars survive escaping" do
    value = %(a "quoted" $HOME and 'single' `tick`)
    args = configuration("headers" => { "response" => { "set" => { "X-Test" => value } } })
      .proxy.deploy_command_args(target: "1.1.1.1")

    flag = args.find { |arg| arg.start_with?("--set-response-header=") }

    # What the shell will hand dash-proxy, once it has removed the quoting.
    assert_equal "X-Test: #{value}", unshell(flag.delete_prefix("--set-response-header="))
  end

  test "a newline in a header value is rejected rather than mangled" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "headers" => { "response" => { "set" => { "X-Test" => "one\ntwo" } } }
    end

    assert_equal "proxy/headers/response/set: 'X-Test' has a value containing a newline or carriage return",
      error.message
  end

  test "an invalid header name is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "headers" => { "request" => { "set" => { "X Bad Name" => "v" } } }
    end

    assert_equal "proxy/headers/request/set: 'X Bad Name' is not a valid header name", error.message
  end

  # Go carries the host in Request.Host, not the header map, so dash-proxy
  # refuses the rule rather than letting it silently do nothing.
  test "a request rule naming Host is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "headers" => { "request" => { "set" => { "Host" => "example.com" } } }
    end

    assert_equal "proxy/headers/request/set: cannot rewrite the Host header", error.message
  end

  test "a response rule may name Host" do
    assert configuration("headers" => { "response" => { "set" => { "Host" => "example.com" } } })
  end

  # Redirects and rewrites

  test "redirects and rewrites become pattern=replacement flags in order" do
    options = deploy_options \
      "redirects" => [ { "from" => "/old", "to" => "/new" }, { "from" => "/gone", "to" => "https://elsewhere.example.com", "status" => 302 } ],
      "rewrites" => [ { "from" => "/api/(.*)", "to" => "/v2/$1" } ]

    assert_equal [ "/old=/new", "/gone=https://elsewhere.example.com;status=302" ], options[:redirect]
    assert_equal [ "/api/(.*)=/v2/$1" ], options[:rewrite]
  end

  # AC2 — StringArrayVar, so one flag per rule and order is preserved.
  test "each redirect is its own repeated flag" do
    args = configuration("redirects" => [ { "from" => "/a", "to" => "/1" }, { "from" => "/b", "to" => "/2" } ])
      .proxy.deploy_command_args(target: "1.1.1.1")

    assert_equal [ "--redirect=\"/a=/1\"", "--redirect=\"/b=/2\"" ], args.grep(/^--redirect=/)
  end

  test "a rule without a from or a to is rejected" do
    assert_equal "proxy/redirects/0: needs both from and to",
      assert_raises(Dash::ConfigurationError) { configuration "redirects" => [ { "to" => "/new" } ] }.message

    assert_equal "proxy/rewrites/0: needs both from and to",
      assert_raises(Dash::ConfigurationError) { configuration "rewrites" => [ { "from" => "/old" } ] }.message
  end

  test "a rewrite replacement must be an absolute path" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "rewrites" => [ { "from" => "/old", "to" => "https://elsewhere.example.com" } ]
    end

    assert_equal "proxy/rewrites/0: to must be an absolute path starting with '/'", error.message
  end

  test "a redirect replacement may be a full URL but not a bare word" do
    assert configuration("redirects" => [ { "from" => "/old", "to" => "https://elsewhere.example.com" } ])

    error = assert_raises(Dash::ConfigurationError) do
      configuration "redirects" => [ { "from" => "/old", "to" => "elsewhere" } ]
    end

    assert_equal "proxy/redirects/0: to must be an absolute path starting with '/' or a full http(s) URL", error.message
  end

  test "a rewrite cannot carry a status" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "rewrites" => [ { "from" => "/old", "to" => "/new", "status" => 302 } ]
    end

    assert_equal "proxy/rewrites/0: status is only meaningful for a redirect", error.message
  end

  test "an unsupported redirect status is rejected" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "redirects" => [ { "from" => "/old", "to" => "/new", "status" => 418 } ]
    end

    assert_equal "proxy/redirects/0: status must be one of 301, 302, 303, 307, 308", error.message
  end

  # The rest

  test "canonical_host becomes --canonical-host" do
    options = deploy_options "canonical_host" => "www.example.com"

    assert_equal "www.example.com", options[:"canonical-host"]
  end

  # dash-proxy rejects the pair (canonical redirection needs a fixed host,
  # on-demand TLS has none) - today the deploy fails after the SSH round-trip.
  test "canonical_host cannot be combined with on_demand_url" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "canonical_host" => "www.example.com", "ssl" => { "on_demand_url" => "/ask" }
    end

    assert_equal "proxy/canonical_host: cannot be combined with ssl/on_demand_url - " \
      "canonical redirection needs a fixed host, and on-demand TLS has none", error.message
  end

  # A canonical host the proxy does not serve is a redirect loop-or-404
  # machine: every request bounces to a hostname no service answers for.
  test "canonical_host must be listed in hosts" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "canonical_host" => "www.example.com", "hosts" => [ "example.com" ]
    end

    assert_equal "proxy/canonical_host: 'www.example.com' is not in hosts - " \
      "every request would redirect to a hostname this service does not serve", error.message
  end

  test "canonical_host in hosts is accepted" do
    assert configuration("canonical_host" => "www.example.com", "hosts" => [ "example.com", "www.example.com" ])
    assert configuration("canonical_host" => "www.example.com", "host" => "www.example.com")
    # Without a static host list (e.g. behind a loadbalancer) there is nothing
    # to check against.
    assert configuration("canonical_host" => "www.example.com")
  end

  # The wire format is '<from>=<to>' and dash-proxy cuts at the FIRST '=', so
  # an '=' inside the pattern silently builds a rule for the wrong path.
  test "redirect and rewrite from cannot contain an equals sign" do
    %w[ redirects rewrites ].each do |key|
      error = assert_raises(Dash::ConfigurationError, "expected #{key} to reject '='") do
        configuration key => [ { "from" => "/old=path", "to" => "/new" } ]
      end

      assert_equal "proxy/#{key}/0: from cannot contain '=' - " \
        "the <from>=<to> wire format cuts at the first '=' and would silently build a different rule", error.message
    end
  end

  test "intercept_errors becomes repeated flags" do
    assert_equal [ 502, 503 ], deploy_options("intercept_errors" => [ 502, 503 ])[:"intercept-errors"]
  end

  test "a non-error status is rejected" do
    error = assert_raises(Dash::ConfigurationError) { configuration "intercept_errors" => [ 200 ] }

    assert_equal "proxy/intercept_errors: 200 must be a 4xx or 5xx status code", error.message
  end

  # AC3: the pairing is not required — the proxy falls back to a bare plaintext
  # status — but that is almost never what the operator wanted.
  test "intercept_errors without error_pages warns" do
    out = stderred { configuration("intercept_errors" => [ 502 ]) }

    assert_match "intercept_errors is set but no error_pages_path", out
  end

  test "no warning when error_pages_path is set" do
    out = stderred do
      Dash::Configuration.new @deploy.merge(error_pages_path: "public", proxy: { "intercept_errors" => [ 502 ] })
    end

    assert_no_match(/intercept_errors is set but no error_pages_path/, out)
  end

  # The load balancer forwards to the per-host proxies, so applying headers and
  # rewrites twice would duplicate an added header and rewrite a path twice
  # over — they stay per-app. Canonical host goes the other way: dash-proxy's
  # redirectURLIfNeeded consults r.TLS, so a per-app redirect behind the LB
  # would emit http:// Locations to HTTPS clients — it moves to the edge.
  test "traffic shaping stays off the load balancer, canonical host moves to it" do
    proxy_config = {
      "loadbalancer" => "lb.example.com", "ssl" => true, "hosts" => [ "app.example.com", "www.example.com" ],
      "headers" => { "request" => { "add" => { "X-Request-Source" => "kamal" } } },
      "rewrites" => [ { "from" => "/(.*)", "to" => "/prefix/$1" } ],
      "canonical_host" => "www.example.com"
    }
    config = configuration(proxy_config)

    assert_equal [ "X-Request-Source: kamal" ], config.proxy.deploy_options[:"add-request-header"]
    assert_not config.proxy.deploy_options.key?(:"canonical-host"), "expected --canonical-host to stay off the per-app proxy"

    loadbalancer = Dash::Configuration::Loadbalancer.new config: config, proxy_config: proxy_config, secrets: config.secrets
    %i[ add-request-header rewrite ].each do |flag|
      assert_not loadbalancer.deploy_options.key?(flag), "expected --#{flag} to stay off the load balancer"
    end
    assert_equal "www.example.com", loadbalancer.deploy_options[:"canonical-host"]
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(proxy_config)
      configuration(proxy_config).proxy.deploy_options
    end

    # Round-trips one shell word through the shell, so the assertion is about
    # what dash-proxy actually receives rather than about the quoting style.
    def unshell(word)
      `printf %s #{word}`
    end
end
