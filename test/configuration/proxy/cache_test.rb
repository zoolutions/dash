require "test_helper"

class ConfigurationProxyCacheTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" }, servers: [ "1.1.1.1" ]
    }
  end

  # Policy — proxy.cache, per service

  test "no cache block leaves the deploy command unchanged" do
    options = deploy_options({})

    assert_not options.key?(:cache)
    assert_not options.key?(:"cache-max-ttl")
    assert_not options.key?(:"cache-allow-set-cookie")
  end

  # Everything but --cache stays out until its key is set: the defaults live in
  # kamal-proxy, the same convention healthcheck_path follows.
  test "enabled alone emits only --cache" do
    options = deploy_options "enabled" => true

    assert_equal true, options[:cache]
    assert_equal [ :cache ], options.keys.grep(/cache/)
  end

  test "durations use the seconds convention and sizes are byte counts" do
    options = deploy_options "enabled" => true, "max_ttl" => 300, "max_body" => 1_048_576, "max_variants" => 8

    assert_equal "300s", options[:"cache-max-ttl"]
    assert_equal 1_048_576, options[:"cache-max-body"]
    assert_equal 8, options[:"cache-max-variants"]
  end

  test "vary_headers and vary_cookies become repeated flags" do
    config = configuration "cache" => {
      "enabled" => true,
      "vary_headers" => [ "Accept-Encoding", "Accept-Language" ],
      "vary_cookies" => [ "locale" ]
    }

    args = config.proxy.deploy_command_args(target: "1.1.1.1")

    assert_includes args, "--cache-vary-header=\"Accept-Encoding\""
    assert_includes args, "--cache-vary-header=\"Accept-Language\""
    assert_includes args, "--cache-vary-cookie=\"locale\""
  end

  test "allow_set_cookie only appears when opted in" do
    assert_equal true, deploy_options("enabled" => true, "allow_set_cookie" => true)[:"cache-allow-set-cookie"]
    assert_not deploy_options("enabled" => true, "allow_set_cookie" => false).key?(:"cache-allow-set-cookie")
  end

  # Store — proxy.run.cache, proxy-wide

  test "no run cache block leaves the run command unchanged" do
    assert_equal "kamal-proxy run --recheck-targets-on-restore", run_config({}).run_command
  end

  test "store tuning becomes kamal-proxy run flags, the store itself never does" do
    run = run_config "store" => "redis://cache.example.com:6379/0", "store_timeout" => 2, "memory_size" => 134_217_728

    assert_equal "kamal-proxy run --recheck-targets-on-restore " \
      "--cache-store-timeout \"2s\" --cache-memory-size \"134217728\"", run.run_command
  end

  # A store URL may carry credentials, and the run command lands in host
  # process listings and kamal's audit log. kamal-proxy reads CACHE_STORE from
  # its environment as the --cache-store default, so the URL travels in the
  # 0600 proxy secrets env file instead - the acme mechanism made shared.
  test "the store travels in the proxy secrets env file, never on the command line" do
    run = run_config "store" => "redis://:supers3cret@cache.example.com:6379/0"

    assert_equal "CACHE_STORE=redis://:supers3cret@cache.example.com:6379/0\n", run.secrets_io.string
    assert_equal ".kamal/proxy/secrets.env", run.secrets_path
    assert_includes run.docker_options_args, "--env-file"
    assert_includes run.docker_options_args, ".kamal/proxy/secrets.env"

    assert_no_match(/supers3cret/, run.run_command)
    assert_no_match(/supers3cret/, run.docker_options_args.join(" "))
  end

  test "acme credentials and the cache store share one secrets env file" do
    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      config = Dash::Configuration.new(@deploy.merge(proxy: { "run" => {
        "acme" => { "email" => "admin@example.com", "credentials" => [ "CF_API_TOKEN" ] },
        "cache" => { "store" => "redis://cache.example.com:6379/0" }
      } }))

      assert_equal "CF_API_TOKEN=zone-rewriting-token\nCACHE_STORE=redis://cache.example.com:6379/0\n",
        config.proxy.run.secrets_io.string
    end
  end

  # Mirrors acme.credential_names: the digest is published as a world-readable
  # docker label, and hashing a URL that may embed a password would hand out an
  # offline guessing target. Presence moves the digest; rotating the URL's
  # value needs an explicit `dash proxy reboot`, same as an acme credential.
  test "config_digest tracks the store's presence, never its value" do
    assert_not_equal run_config({}).config_digest, run_config("store" => "memory").config_digest
    assert_equal run_config("store" => "memory").config_digest,
      run_config("store" => "redis://:supers3cret@cache.example.com:6379/0").config_digest
  end

  # Validation

  test "policy keys without enabled are a config error" do
    error = assert_raises(Dash::ConfigurationError) { configuration "cache" => { "max_ttl" => 300 } }

    assert_equal "proxy/cache: max_ttl has no effect without enabled: true - " \
      "kamal-proxy ignores the cache policy entirely when --cache is absent", error.message
  end

  test "enabled false with policy keys is the same error" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "cache" => { "enabled" => false, "vary_cookies" => [ "locale" ] }
    end

    assert_equal "proxy/cache: vary_cookies has no effect without enabled: true - " \
      "kamal-proxy ignores the cache policy entirely when --cache is absent", error.message
  end

  test "an unsupported store fails at config time" do
    error = assert_raises(Dash::ConfigurationError) do
      configuration "run" => { "cache" => { "store" => "memcached://cache.example.com" } }
    end

    assert_equal "proxy/run/cache: store must be 'memory' or a redis:// or rediss:// URL", error.message
  end

  test "memory and redis stores are accepted" do
    assert configuration("run" => { "cache" => { "store" => "memory" } })
    assert configuration("run" => { "cache" => { "store" => "redis://cache.example.com:6379/0" } })
    assert configuration("run" => { "cache" => { "store" => "rediss://cache.example.com:6379/0" } })
  end

  private
    def configuration(proxy_config)
      Dash::Configuration.new @deploy.merge(proxy: proxy_config)
    end

    def deploy_options(cache_config)
      configuration(cache_config.present? ? { "cache" => cache_config } : {}).proxy.deploy_options
    end

    def run_config(cache_config)
      config = Dash::Configuration.new(@deploy)
      run = cache_config.present? ? { "cache" => cache_config } : {}

      Dash::Configuration::Proxy::Run.new(config, run_config: run)
    end
end
